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
# Pinned versions (change deliberately — these are load-bearing):
#   zig            0.15.2   ghostty v1.3.1 pins it; newer zig changes the build API.
#   ghostty        v1.3.1   the embedding API this app links against.
#   macOS SDK      15.5     zig 0.15.2's linker can't parse the macOS 26 SDK; 15.5 works.
#   Metal Toolchain required, separate download (`xcodebuild -downloadComponent MetalToolchain`).
#                           Not version-pinned by us — it tracks the installed Xcode.
#
# Usage:
#   bash scripts/build-libghostty.sh           build + stage (idempotent)
#   bash scripts/build-libghostty.sh --check    verify prerequisites only; build nothing
#   CHECK=1 bash scripts/build-libghostty.sh    same as --check
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
MODE="build"

usage() {
  cat <<EOF
Usage: bash scripts/build-libghostty.sh [--check]
  (no args)   build Vendor/libghostty.a + stage ghostty.h (idempotent)
  --check     verify prerequisites (host tools + Metal toolchain) and report; build nothing
  -h, --help  show this help
Env: CHECK=1 is equivalent to --check.
EOF
}

parse_args() {
  [ "${CHECK:-0}" = 1 ] && MODE="check"
  for a in "$@"; do
    case "$a" in
      --check) MODE="check" ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown argument: $a" >&2; usage >&2; exit 2 ;;
    esac
  done
}

print_pins() {
  echo "==> pins: zig ${ZIG_VERSION} | ghostty ${GHOSTTY_TAG} | macOS SDK ${SDK_VERSION} | Metal Toolchain: required (separate download, tracks Xcode)"
}

# True if the archive exists and exports the libghostty embedding API. nm's output (~68k symbols)
# is captured first rather than piped into `grep -q`: with `set -o pipefail`, grep's early-exit on a
# match closes the pipe, nm gets SIGPIPE mid-write, and the pipeline reports *failure* — a flaky race
# that made a present archive read as "not built". Capturing nm first removes the pipe entirely.
has_embedding_api() {   # $1 = archive path
  [ -f "$1" ] || return 1
  local syms
  syms="$(nm "$1" 2>/dev/null)" || return 1
  grep -q ' T _ghostty_app_new' <<<"$syms"
}

# ---- preflight: required host tools ----
preflight() {
  local missing=() t
  for t in xcode-select xcrun xcodebuild curl git python3 tar ar nm libtool uname mktemp; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing required tools: ${missing[*]}" >&2
    echo "       Install full Xcode + the command line tools, then re-run." >&2
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    arm64)  ZARCH="aarch64" ;;
    x86_64) ZARCH="x86_64" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
}

# ---- Metal Toolchain detection ----
# `xcrun -f metal` only proves a path resolves, not that the compiler works (the toolchain is a
# separately-mounted component). So actually compile a trivial shader: invocation, not resolution,
# proves the asset is present and usable. Returns nonzero without printing on failure.
metal_toolchain_works() {   # $1 = candidate DEVELOPER_DIR
  local dev="$1" metal metallib tmp rc=0
  metal="$(DEVELOPER_DIR="$dev" xcrun -sdk macosx -f metal 2>/dev/null)" || return 1
  metallib="$(DEVELOPER_DIR="$dev" xcrun -sdk macosx -f metallib 2>/dev/null)" || return 1
  [ -x "$metal" ] && [ -x "$metallib" ] || return 1
  tmp="$(mktemp -d)"
  printf '#include <metal_stdlib>\nusing namespace metal;\nkernel void _probe() {}\n' > "$tmp/probe.metal"
  if ! "$metal" -c "$tmp/probe.metal" -o "$tmp/probe.air" >/dev/null 2>&1; then rc=1; fi
  if [ $rc -eq 0 ] && ! "$metallib" "$tmp/probe.air" -o "$tmp/probe.metallib" >/dev/null 2>&1; then rc=1; fi
  rm -rf "$tmp"
  return $rc
}

# Find an Xcode whose Metal toolchain actually compiles; sets XDEV/METAL/METALLIB. Soft (no exit).
find_metal_toolchain() {
  XDEV=""
  for cand in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer /Applications/Xcode-*.app/Contents/Developer; do
    [ -d "$cand" ] || continue
    if metal_toolchain_works "$cand"; then XDEV="$cand"; break; fi
  done
  [ -n "$XDEV" ] || return 1
  METAL="$(DEVELOPER_DIR="$XDEV" xcrun -sdk macosx -f metal)"
  METALLIB="$(DEVELOPER_DIR="$XDEV" xcrun -sdk macosx -f metallib)"
  return 0
}

metal_help() {
  cat >&2 <<EOF

A working Metal toolchain was not found. ghostty compiles its Metal shaders at build time and
needs full Xcode plus the separately-downloaded Metal Toolchain component.

Fix:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  xcodebuild -downloadComponent MetalToolchain     # large download; may prompt to accept the Xcode license
  bash scripts/build-libghostty.sh --check         # re-verify
EOF
}

require_metal_toolchain() {
  if find_metal_toolchain; then
    echo "==> Xcode:    $XDEV"
    echo "==> metal:    $METAL"
    echo "==> metallib: $METALLIB"
  else
    metal_help
    exit 1
  fi
}

# ---- fast preflight-only mode: report status, build nothing, exit 0/1 ----
check() {
  local rc=0
  echo "==> bosun libghostty preflight"
  if find_metal_toolchain; then
    echo "  [ok]   Metal toolchain compiles a trivial shader ($XDEV)"
  else
    echo "  [FAIL] Metal toolchain cannot compile a trivial shader"; rc=1
  fi
  if [ -x "$VENDOR/zig/zig" ] && "$VENDOR/zig/zig" version 2>/dev/null | grep -q "^${ZIG_VERSION}$"; then
    echo "  [ok]   zig ${ZIG_VERSION} present"
  else
    echo "  [..]   zig ${ZIG_VERSION} will be downloaded"
  fi
  if [ -d "$VENDOR/sdk/MacOSX${SDK_VERSION}.sdk" ]; then
    echo "  [ok]   macOS ${SDK_VERSION} SDK present"
  else
    echo "  [..]   macOS ${SDK_VERSION} SDK will be downloaded"
  fi
  if [ -d "$VENDOR/ghostty/.git" ]; then
    echo "  [ok]   ghostty source present"
  else
    echo "  [..]   ghostty ${GHOSTTY_TAG} will be cloned"
  fi
  if has_embedding_api "$VENDOR/libghostty.a"; then
    echo "  [ok]   Vendor/libghostty.a present and exports the embedding API"
  else
    echo "  [..]   Vendor/libghostty.a not built yet"
  fi
  if [ $rc -eq 0 ]; then
    echo "==> preflight OK"
  else
    echo "==> preflight FAILED"
    metal_help
  fi
  return $rc
}

# ---- 1. zig 0.15.2 ----
ensure_zig() {
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
}

# ---- 2. macOS 15.5 SDK ----
ensure_sdk() {
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
}

# ---- 4. hybrid developer dir: Xcode tools + 15.5 SDK (CLT-style) ----
make_hybrid_devdir() {
  DEVDIR="$VENDOR/devdir"
  rm -rf "$DEVDIR"; mkdir -p "$DEVDIR/SDKs"
  for d in usr Toolchains Library; do [ -e "$XDEV/$d" ] && ln -s "$XDEV/$d" "$DEVDIR/$d"; done
  ln -s "$SDK" "$DEVDIR/SDKs/MacOSX.sdk"
  ln -s "$SDK" "$DEVDIR/SDKs/MacOSX${SDK_VERSION}.sdk"
}

# ---- 5. clone ghostty ----
clone_ghostty() {
  SRC="$VENDOR/ghostty"
  if [ -d "$SRC/.git" ]; then
    echo "==> ghostty source present"
  else
    echo "==> cloning ghostty $GHOSTTY_TAG"
    rm -rf "$SRC"
    git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty "$SRC"
  fi
}

# ---- 5b. patch MetallibStep to call metal/metallib by absolute path (bypass xcrun) ----
patch_metallib() {
  local MLS="$SRC/src/build/MetallibStep.zig"
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
  # Post-condition: the xcrun calls must be gone. If they aren't, a future ghostty layout change
  # silently broke the patch — fail loudly here instead of producing an unbuildable tree.
  if grep -q '/usr/bin/xcrun' "$MLS"; then
    echo "ERROR: MetallibStep still references /usr/bin/xcrun after patching." >&2
    echo "       ghostty's build layout changed; update patch_metallib in this script." >&2
    exit 1
  fi
}

# ---- 5c. xcrun shim ----
# Many zig packages (apple-sdk, zig_objc, …) detect the SDK via std.zig getSdk, which runs
# `xcrun --sdk macosx --show-sdk-path` (PATH-resolved). xcrun rejects the hybrid DEVELOPER_DIR,
# so we shim it to return the 15.5 SDK; anything else falls through to the real xcrun (real Xcode).
make_xcrun_shim() {
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
}

# ---- 6. build the static archives ----
# We ask for the xcframework because that target compiles libghostty.a + all its dependency
# archives (cimgui, freetype, glslang, …). We do NOT need the xcframework itself: its final
# packaging runs `xcodebuild -create-xcframework` (rejects the hybrid dir) and installs locale
# .mo files via `msgfmt` (gettext, not installed) — both fail, AFTER every archive we need is
# already built. So we tolerate that tail failure and harvest the archives below.
build_archives() {
  LIBA="$VENDOR/libghostty.a"
  if has_embedding_api "$LIBA"; then
    echo "==> libghostty.a present (delete it to rebuild)"
  else
    echo "==> building libghostty (several minutes)…"
    ( cd "$SRC" && DEVELOPER_DIR="$DEVDIR" SDKROOT="$SDK" PATH="$SHIM:$PATH" "$ZIG" build \
        -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework=true -Dxcframework-target=native ) \
      || echo "   (xcframework/locale packaging failed as expected; harvesting archives)"
    merge_archives
  fi
}

# ---- 7. merge all static archives into one Apple-aligned fat archive ----
# zig writes archive members the macOS 26 linker rejects ("not 8-byte aligned"), and ghostty's
# own LibtoolStep merges archives directly (which mis-handles those members on macOS 26). So we
# extract every object and re-archive them with Apple libtool, which writes aligned members.
merge_archives() {
  LIBA="$VENDOR/libghostty.a"
  echo "==> merging static archives with libtool"
  WORK="$VENDOR/relib"; rm -rf "$WORK"; mkdir -p "$WORK"
  # Dedup archive basenames without an associative array: `declare -A` is bash 4+, but macOS's
  # system bash is 3.2 and the script must run there too. A space-delimited seen-list does it; the
  # basenames are plain `lib*.a`, so the glob match in `case` is safe.
  seen=" "; i=0
  while read -r a; do
    b="$(basename "$a")"
    case "$seen" in *" $b "*) continue ;; esac
    seen="$seen$b "
    d="$WORK/d$i"; mkdir -p "$d"; ( cd "$d" && ar x "$a" ); i=$((i+1))
  done < <(find "$SRC/.zig-cache" -name '*.a' | sort)
  ( cd "$WORK" && chmod -R u+rw . && find . -name '*.o' -type f > objs.txt \
      && /usr/bin/libtool -static -o "$LIBA" -filelist objs.txt )
  rm -rf "$WORK"
}

verify_archive() {
  has_embedding_api "$VENDOR/libghostty.a" \
    || { echo "fat libghostty.a is missing the embedding API" >&2; exit 1; }
}

# ---- 8. stage the header ----
stage_header() {
  cp "$SRC/include/ghostty.h" "$ROOT/Sources/CGhostty/include/ghostty.h"
}

done_banner() {
  echo
  echo "==> DONE: $VENDOR/libghostty.a ($(du -h "$VENDOR/libghostty.a" | cut -f1)) + ghostty.h staged."
  echo "    Now: swift build && swift run Workbench"
}

main() {
  parse_args "$@"
  print_pins
  preflight
  detect_arch

  if [ "$MODE" = "check" ]; then
    if check; then exit 0; else exit 1; fi
  fi

  ensure_zig
  ensure_sdk
  require_metal_toolchain
  make_hybrid_devdir
  clone_ghostty
  patch_metallib
  make_xcrun_shim
  build_archives
  verify_archive
  stage_header
  done_banner
}

mkdir -p "$VENDOR" "$ROOT/Sources/CGhostty/include"
main "$@"
