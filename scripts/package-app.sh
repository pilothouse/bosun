#!/usr/bin/env bash
# Wrap the built Bosun executable into a distributable Bosun.app and a Bosun.dmg.
#
# Bosun builds as a *bare* SwiftPM executable: just `.build/release/Bosun` plus a co-located
# `Bosun_Bosun.bundle` (the SwiftPM resource bundle that carries AppIcon.png, loaded at runtime
# via `Bundle.module`). A bare executable has no Info.plist and won't drag-install — you can't
# hand it to someone on another Mac. This script assembles the real `.app` layout around it:
#
#   Bosun.app/Contents/
#     ├── Info.plist                 generated here (none exists in the source tree)
#     ├── MacOS/Bosun                the executable
#     └── Resources/
#         ├── AppIcon.icns           generated from Sources/Bosun/Resources/AppIcon.png
#         └── Bosun_Bosun.bundle     SwiftPM resource bundle (carries AppIcon.png). It lives in
#                                    Resources/ — the first path `Bundle.module` searches is
#                                    Bundle.main.resourceURL — and that's also where codesign seals
#                                    it as plain data. It has no Info.plist, so it is NOT a code
#                                    bundle; signing it (or using `codesign --deep`) fails on it.
#
# Then it ad-hoc code-signs the bundle (required for the app to launch at all on Apple Silicon)
# and rolls a compressed .dmg with a drag-to-/Applications symlink.
#
# This is a pre-v1 convenience build: single-architecture (the host arch — arm64 on the CI
# runners and on Apple Silicon Macs) and *not* notarized. Gatekeeper will quarantine it on first
# open; the recipient clears it once (right-click → Open, or `xattr -dr com.apple.quarantine`).
#
# Usage:
#   bash scripts/package-app.sh            package the release build into dist/Bosun.dmg
# Env (all optional):
#   CONFIG   build configuration to package (default: release)
#   VERSION  CFBundleShortVersionString    (default: 0.0.0)
#   BUILD    CFBundleVersion               (default: 0)
#   BIN_DIR  build products dir            (default: `swift build -c $CONFIG --show-bin-path`)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-0}"
APP_NAME="Bosun"
BUNDLE_ID="com.jeckerson.bosun"
ICON_SRC="$ROOT/Sources/Bosun/Resources/AppIcon.png"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

# Locate the build products. `--show-bin-path` doesn't build; it just resolves the path, so this
# is cheap and works whether or not the caller already ran `swift build`.
BIN_DIR="${BIN_DIR:-$(swift build -c "$CONFIG" --show-bin-path)}"
EXE="$BIN_DIR/$APP_NAME"
RES_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"

[ -x "$EXE" ] || { echo "ERROR: executable not found at $EXE — run 'swift build -c $CONFIG --product $APP_NAME' first" >&2; exit 1; }

echo "==> packaging $APP_NAME $VERSION (build $BUILD) from $BIN_DIR"

# ---- 1. clean app skeleton ----
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ---- 2. executable + its resource bundle (in Resources/, see header) ----
cp "$EXE" "$APP/Contents/MacOS/$APP_NAME"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
  echo "   WARNING: $RES_BUNDLE missing — the app icon won't load (Bundle.module resource bundle absent)" >&2
fi

# ---- 3. .icns from the 1024px AppIcon.png (sips downscales, iconutil packs the iconset) ----
if [ -f "$ICON_SRC" ]; then
  echo "==> generating AppIcon.icns"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"            "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "   WARNING: $ICON_SRC missing — packaging without a Finder icon" >&2
fi

# ---- 4. Info.plist ----
# The source tree has none (the dock icon is set at runtime via NSApp.applicationIconImage), so
# the bundle's metadata is authored here. LSMinimumSystemVersion mirrors Package.swift's .macOS(.v13).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
	<key>CFBundleExecutable</key>      <string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
	<key>CFBundleShortVersionString</key> <string>$VERSION</string>
	<key>CFBundleVersion</key>         <string>$BUILD</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleIconFile</key>        <string>AppIcon</string>
	<key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
	<key>LSMinimumSystemVersion</key>  <string>13.0</string>
	<key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key> <true/>
	<key>NSPrincipalClass</key>        <string>NSApplication</string>
	<key>NSHumanReadableCopyright</key> <string>Bosun</string>
</dict>
</plist>
PLIST

# ---- 5. ad-hoc code signature ----
# Apple Silicon refuses to launch an unsigned binary; an ad-hoc signature (identity "-") satisfies
# that without a Developer ID. No `--deep`: the only nested item is the resource bundle, which has
# no Info.plist and so isn't a signable code bundle — codesign seals it as a plain resource. This
# is NOT notarized, so Gatekeeper still quarantines downloads — recipients clear it once (header).
echo "==> ad-hoc signing $APP_NAME.app"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" && echo "   signature verified"

# ---- 6. compressed .dmg with a drag-to-Applications target ----
echo "==> building $APP_NAME.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "==> DONE: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    Install: open the .dmg, drag $APP_NAME to Applications."
echo "    First launch (unsigned): right-click → Open, or  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
