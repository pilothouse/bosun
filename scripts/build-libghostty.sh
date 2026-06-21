#!/usr/bin/env bash
# Build a linkable libghostty from source and stage it for SwiftPM.
#
# This machine is macOS 26 (Tahoe) with full Xcode + the Metal Toolchain. Two obstacles:
#   1. ghostty v1.3.1 pins zig 0.15.2, whose linker can't parse the macOS 26 SDK's libSystem tbd
#      (every libSystem symbol comes up undefined). Fix: build against an older macOS 15.5 SDK,
#      fed to zig via a "hybrid" DEVELOPER_DIR (Xcode's tools + a CLT-style SDKs/MacOSX.sdk -> 15.5).
#      zig ignores SDKROOT and, when xcrun fails for that hybrid dir, falls back to DEVELOPER_DIR/SDKs.
#   2. ghostty compiles its Metal shaders with `xcrun metal`, but xcrun rejects the hybrid DEVELOPER_DIR.
#      Fix: patch ghostty's MetallibStep to invoke the metal/metallib compilers by absolute path
#      (resolved from the real Xcode), which need neither xcrun nor a developer dir.
#
# Idempotent. Outputs:
#   Vendor/libghostty.a                 (static archive, host arch)
#   Sources/CGhostty/include/ghostty.h  (embedding header)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
ZIG_VERSION="0.15.2"
GHOSTTY_TAG="v1.3.1"
SDK_VERSION="15.5"
mkdir -p "$VENDOR" "$ROOT/Sources/CGhostty/include"

UNAME_M="$(uname -m)"
case "$UNAME_M" in
  arm64)  ZARCH="aarch64" ;;
  x86_64) ZARCH="x86_64" ;;
  *) echo "unsupported arch: $UNAME_M" >&2; exit 1 ;;
esac

# ---- 1. zig 0.15.2 ----
ZIG_DIR="$VENDOR/zig"; ZIG="$ZIG_DIR/zig"
if [ -x "$ZIG" ] && "$ZIG" version 2>/dev/null | grep -q "^${ZIG_VERSION}$"; then
  echo "==> zig ${ZIG_VERSION} present"
else
  echo "==> downloading zig ${ZIG_VERSION}"
  rm -rf "$ZIG_DIR"; mkdir -p "$ZIG_DIR"; TARBALL="$VENDOR/zig.tar.xz"; OK=""
  for u in \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-macos-${ZIG_VERSION}.tar.xz" \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-macos-${ZARCH}-${ZIG_VERSION}.tar.xz"; do
    if curl -fL --retry 3 -o "$TARBALL" "$u"; then OK=1; break; fi
  done
  [ -n "$OK" ] || { echo "could not download zig" >&2; exit 1; }
  tar -xf "$TARBALL" -C "$ZIG_DIR" --strip-components=1; rm -f "$TARBALL"
fi
"$ZIG" version

# ---- 2. macOS 15.5 SDK ----
SDK="$VENDOR/sdk/MacOSX${SDK_VERSION}.sdk"
if [ -d "$SDK" ]; then
  echo "==> macOS ${SDK_VERSION} SDK present"
else
  echo "==> downloading macOS ${SDK_VERSION} SDK"
  mkdir -p "$VENDOR/sdk"
  curl -fL --retry 3 -o "$VENDOR/sdk/sdk.tar.xz" \
    "https://github.com/joseluisq/macosx-sdks/releases/download/${SDK_VERSION}/MacOSX${SDK_VERSION}.sdk.tar.xz"
  tar -xf "$VENDOR/sdk/sdk.tar.xz" -C "$VENDOR/sdk"; rm -f "$VENDOR/sdk/sdk.tar.xz"
fi
[ -d "$SDK" ] || { echo "SDK missing at $SDK" >&2; exit 1; }

# ---- 3. locate full Xcode + the Metal compiler ----
XDEV=""
for cand in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer /Applications/Xcode-*.app/Contents/Developer; do
  [ -d "$cand" ] || continue
  if DEVELOPER_DIR="$cand" xcrun -sdk macosx -f metal >/dev/null 2>&1; then XDEV="$cand"; break; fi
done
if [ -z "$XDEV" ]; then
  cat >&2 <<EOF

ERROR: Metal compiler not found. ghostty compiles its shaders at build time and needs
full Xcode + the Metal Toolchain:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  xcodebuild -downloadComponent MetalToolchain
then re-run this script.
EOF
  exit 1
fi
METAL="$(DEVELOPER_DIR="$XDEV" xcrun -sdk macosx -f metal)"
METALLIB="$(DEVELOPER_DIR="$XDEV" xcrun -sdk macosx -f metallib)"
echo "==> Xcode: $XDEV"
echo "==> metal: $METAL"

# ---- 4. hybrid developer dir: Xcode tools + 15.5 SDK (CLT-style) ----
DEVDIR="$VENDOR/devdir"
rm -rf "$DEVDIR"; mkdir -p "$DEVDIR/SDKs"
for d in usr Toolchains Library; do [ -e "$XDEV/$d" ] && ln -s "$XDEV/$d" "$DEVDIR/$d"; done
ln -s "$SDK" "$DEVDIR/SDKs/MacOSX.sdk"
ln -s "$SDK" "$DEVDIR/SDKs/MacOSX${SDK_VERSION}.sdk"

# ---- 5. clone ghostty ----
SRC="$VENDOR/ghostty"
if [ -d "$SRC/.git" ]; then
  echo "==> ghostty source present"
else
  echo "==> cloning ghostty $GHOSTTY_TAG"
  rm -rf "$SRC"
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty "$SRC"
fi

# ---- 5b. patch MetallibStep to call metal/metallib by absolute path (bypass xcrun) ----
MLS="$SRC/src/build/MetallibStep.zig"
if grep -q '/usr/bin/xcrun' "$MLS"; then
  echo "==> patching MetallibStep to use absolute metal compiler"
  python3 - "$MLS" "$METAL" "$METALLIB" <<'PY'
import sys
path, metal, metallib = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = s.replace('"/usr/bin/xcrun", "-sdk", sdk, "metal", "-o"',  '"%s", "-o"' % metal)
s = s.replace('"/usr/bin/xcrun", "-sdk", sdk, "metallib", "-o"', '"%s", "-o"' % metallib)
# `sdk` is now unused; discard it right after its declaration block.
s = s.replace("    const self = b.allocator.create(MetallibStep) catch @panic(\"OOM\");",
              "    _ = sdk;\n    const self = b.allocator.create(MetallibStep) catch @panic(\"OOM\");", 1)
open(path, "w").write(s)
print("   patched", path)
PY
fi

# ---- 5c. xcrun shim ----
# Many zig packages (apple-sdk, zig_objc, …) detect the SDK via std.zig getSdk, which runs
# `xcrun --sdk macosx --show-sdk-path` (PATH-resolved). xcrun rejects the hybrid DEVELOPER_DIR,
# so we shim it to return the 15.5 SDK; anything else falls through to the real xcrun (real Xcode).
SHIM="$VENDOR/shim"
rm -rf "$SHIM"; mkdir -p "$SHIM"
cat > "$SHIM/xcrun" <<EOF
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "--show-sdk-path" ] && { printf '%s\n' "$SDK"; exit 0; }
done
exec env DEVELOPER_DIR="$XDEV" /usr/bin/xcrun "\$@"
EOF
chmod +x "$SHIM/xcrun"

# ---- 6. build the static archives ----
# We ask for the xcframework because that target compiles libghostty.a + all its dependency
# archives (cimgui, freetype, glslang, …). We do NOT need the xcframework itself: its final
# packaging runs `xcodebuild -create-xcframework` (rejects the hybrid dir) and installs locale
# .mo files via `msgfmt` (gettext, not installed) — both fail, AFTER every archive we need is
# already built. So we tolerate that tail failure and harvest the archives below.
LIBA="$VENDOR/libghostty.a"
if [ -f "$LIBA" ] && nm "$LIBA" 2>/dev/null | grep -q ' T _ghostty_app_new'; then
  echo "==> libghostty.a present (delete it to rebuild)"
else
  echo "==> building libghostty (several minutes)…"
  ( cd "$SRC" && DEVELOPER_DIR="$DEVDIR" SDKROOT="$SDK" PATH="$SHIM:$PATH" "$ZIG" build \
      -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework=true -Dxcframework-target=native ) \
    || echo "   (xcframework/locale packaging failed as expected; harvesting archives)"

  # ---- 7. merge all static archives into one Apple-aligned fat archive ----
  # zig writes archive members the macOS 26 linker rejects ("not 8-byte aligned"), and ghostty's
  # own LibtoolStep merges archives directly (which mis-handles those members on macOS 26). So we
  # extract every object and re-archive them with Apple libtool, which writes aligned members.
  echo "==> merging static archives with libtool"
  WORK="$VENDOR/relib"; rm -rf "$WORK"; mkdir -p "$WORK"
  declare -A seen; i=0
  while read -r a; do
    b="$(basename "$a")"; [ -n "${seen[$b]:-}" ] && continue; seen[$b]=1
    d="$WORK/d$i"; mkdir -p "$d"; ( cd "$d" && ar x "$a" ); i=$((i+1))
  done < <(find "$SRC/.zig-cache" -name '*.a' | sort)
  ( cd "$WORK" && chmod -R u+rw . && find . -name '*.o' -type f > objs.txt \
      && /usr/bin/libtool -static -o "$LIBA" -filelist objs.txt )
  rm -rf "$WORK"
fi
nm "$LIBA" 2>/dev/null | grep -q ' T _ghostty_app_new' \
  || { echo "fat libghostty.a is missing the embedding API" >&2; exit 1; }

# ---- 8. stage the header ----
cp "$SRC/include/ghostty.h" "$ROOT/Sources/CGhostty/include/ghostty.h"

echo
echo "==> DONE: $LIBA ($(du -h "$LIBA" | cut -f1)) + ghostty.h staged."
echo "    Now: swift build && swift run Workbench"
