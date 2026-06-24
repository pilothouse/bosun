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
# Then it code-signs the app with the hardened runtime, optionally notarizes + staples it, and
# rolls a compressed .dmg with a drag-to-/Applications symlink.
#
# Signing is env-driven (see SIGN_IDENTITY below):
#   - With a Developer ID Application identity: hardened runtime + entitlements + secure timestamp,
#     then (if notary credentials are set) `notarytool` submit + `stapler` staple of BOTH the .app
#     and the .dmg → a Gatekeeper-clean download that opens with no right-click workaround.
#   - With no identity: an ad-hoc signature (identity "-"), still with the hardened runtime so the
#     convenience build behaves identically. This path is NOT notarized — Gatekeeper quarantines it
#     on first open; the recipient clears it once (right-click → Open, or `xattr -dr com.apple.quarantine`).
# Either way the build is single-architecture (the host arch — arm64 on CI and Apple Silicon Macs);
# a universal notarized DMG is the release workflow's job, not this convenience script's.
#
# Usage:
#   bash scripts/package-app.sh            package the release build into dist/Bosun.dmg
# Env (all optional):
#   CONFIG         build configuration to package (default: release)
#   VERSION        CFBundleShortVersionString    (default: 0.0.0)
#   BUILD          CFBundleVersion               (default: 0)
#   BIN_DIR        build products dir            (default: `swift build -c $CONFIG --show-bin-path`)
#   SIGN_IDENTITY  Developer ID Application identity, e.g. "Developer ID Application: Name (TEAMID)".
#                  Empty → ad-hoc signature (un-notarizable convenience build).
#   NOTARY_PROFILE / NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER
#                  Apple notary credentials, consumed by scripts/notarize.sh. Empty → sign only
#                  (no notarization). See docs/signing.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-0}"
APP_NAME="Bosun"
BUNDLE_ID="com.jeckerson.bosun"
ICON_SRC="$ROOT/Sources/Bosun/Resources/AppIcon.png"
ENTITLEMENTS="$ROOT/scripts/Bosun.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

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

# ---- 5. code signature (hardened runtime) ----
# Sign the .app EXPLICITLY, never with `--deep`: the only nested item is the resource bundle, which
# has no Info.plist and so isn't a signable code bundle — `--deep` would try to sign it and fail.
# Signing the bundle (without --deep) signs the main Mach-O and seals the resource bundle as a plain
# resource, which is exactly what we want. `--options runtime` enables the hardened runtime that
# notarization requires; the entitlements file is empty today (see scripts/Bosun.entitlements).
#
# With a Developer ID identity we add `--timestamp` (a secure Apple timestamp, mandatory for
# notarization). Ad-hoc (identity "-") can't use Apple's TSA, so it omits `--timestamp` — Apple
# Silicon still needs *a* signature to launch, and the hardened runtime keeps both paths identical.
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> signing $APP_NAME.app with Developer ID: $SIGN_IDENTITY"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> ad-hoc signing $APP_NAME.app (no SIGN_IDENTITY — un-notarizable convenience build)"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --strict --deep --verbose=2 "$APP" && echo "   signature verified"
codesign --display --entitlements - --verbose=2 "$APP" 2>/dev/null || true

# ---- 5b. notarize + staple the .app ----
# The notary service takes a .zip but `stapler` writes the ticket into the .app, so we submit a
# ditto-zip and staple the .app. Stapling the app (not just the .dmg) keeps it valid even after a
# user drags it out of the disk image. No-op when no notary credentials are set (header / notarize.sh).
APP_ZIP="$DIST/$APP_NAME.app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
bash "$ROOT/scripts/notarize.sh" --submit "$APP_ZIP" --staple "$APP"
rm -f "$APP_ZIP"

# ---- 6. compressed .dmg with a drag-to-Applications target ----
echo "==> building $APP_NAME.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ---- 6b. sign + notarize + staple the .dmg ----
# Sign the disk image itself (Developer ID only) so it carries a verifiable signature, then notarize
# and staple it so the *download* opens cleanly — Gatekeeper reads the stapled ticket offline.
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> signing $APP_NAME.dmg"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
bash "$ROOT/scripts/notarize.sh" --submit "$DMG" --staple "$DMG"

echo
echo "==> DONE: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    Install: open the .dmg, drag $APP_NAME to Applications."
if [ -n "$SIGN_IDENTITY" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY:-}" ]; }; then
  echo "    Signed (Developer ID) + notarized + stapled — opens with no Gatekeeper workaround."
else
  echo "    Not notarized: first launch needs right-click → Open, or  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
fi
