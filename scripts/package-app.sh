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
#                                    Resources/ — the standard, code-signable spot, where codesign
#                                    seals it as plain data. It has no Info.plist, so it is NOT a code
#                                    bundle; signing it (or using `codesign --deep`) fails on it.
#                                    NOTE: the app does NOT reach this via `Bundle.module`. The Swift
#                                    6 generated accessor only probes `Bundle.main.bundleURL/<name>`
#                                    (the .app *root*, not Resources/) and the absolute build path,
#                                    so it `fatalError`s at launch on any other machine. AppDelegate
#                                    loads the bundle by hand from Resources/ instead — keep it here.
#
# Then it code-signs the app with the hardened runtime, optionally notarizes + staples it, and
# rolls a compressed .dmg with a drag-to-/Applications symlink.
#
# Signing is env-driven (see SIGN_IDENTITY below):
#   - With a Developer ID Application identity: hardened runtime + entitlements + secure timestamp,
#     then (if notary credentials are set) `notarytool` submit + `stapler` staple of BOTH the .app
#     and the .dmg → a Gatekeeper-clean download that opens with no right-click workaround.
#   - With no identity: an ad-hoc signature (identity "-"), WITHOUT the hardened runtime. Once
#     Sparkle.framework is embedded, a team-less ad-hoc + hardened runtime fails library validation and
#     the app is SIGKILLed at launch (see §5); the convenience build is never notarized, so it drops the
#     hardened runtime to stay launchable. This path is NOT notarized — Gatekeeper quarantines it on first
#     open; the recipient clears it once (right-click → Open, or `xattr -dr com.apple.quarantine`).
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
#   PROVISION_PROFILE
#                  Path to a Developer ID .provisionprofile. Needed only when the entitlements declare
#                  a restricted `com.apple.developer.*` capability (iCloud, App Groups, push, Sign in
#                  with Apple); embedded at Contents/embedded.provisionprofile before signing.
#                  Empty → skipped, with a warning if the entitlements ask for one.
#   NOTARY_PROFILE / NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER
#                  Apple notary credentials, consumed by scripts/notarize.sh. Empty → sign only
#                  (no notarization).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-0}"
APP_NAME="Bosun"
BUNDLE_ID="dev.anvas.bosun"
ICON_SRC="$ROOT/Sources/Bosun/Resources/AppIcon.png"
# Signing and notarizing live outside this repo, so releases are cut by hand rather than by CI. Both
# of the files below are kept with that release tooling. This script keeps working without them: it
# builds and ad-hoc signs, which is all CI needs. Point the vars at that tooling to sign locally in
# one pass instead.
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/scripts/Bosun.entitlements}"
NOTARIZE_SH="${NOTARIZE_SH:-$ROOT/scripts/notarize.sh}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Sparkle auto-update (issue #57). The feed is the signed appcast attached to the latest GitHub
# Release; `releases/latest/download/<asset>` always resolves to the newest *published* release, so the
# feed needs no separate hosting and stays in step with the assets it advertises.
#
# One property to be aware of: this URL is burned into every shipped Info.plist and can never be
# changed for copies already installed, so it pins the app to this repo owner. A later rename or move
# keeps working only for as long as GitHub's redirect does. Settle the org before the first release.
#
# SU_PUBLIC_ED_KEY is the EdDSA public key — NOT a secret; it's pinned in every shipped Info.plist and
# verifies the appcast's signature. It pairs with a private key the maintainer holds (login Keychain,
# account "bosun") and stores as the CI secret SPARKLE_ED_PRIVATE_KEY. To rotate, run
# `scripts/.../generate_keys` and replace BOTH this value and the secret.
SU_FEED_URL="https://github.com/pilothouse/bosun/releases/latest/download/appcast.xml"
SU_PUBLIC_ED_KEY="Kj1rSUcSqZQLkP6KAw+vKhJJZ9pYAF3jHrL9rr2BRI8="

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
	<key>SUFeedURL</key>               <string>$SU_FEED_URL</string>
	<key>SUPublicEDKey</key>           <string>$SU_PUBLIC_ED_KEY</string>
</dict>
</plist>
PLIST

# ---- 4b. embed Sparkle.framework (auto-update, issue #57) ----
# The executable links @rpath/Sparkle.framework; Package.swift adds an @executable_path/../Frameworks
# rpath, so the framework must live in Contents/Frameworks for the packaged app to launch. SwiftPM stages
# a ready (universal arm64+x86_64) copy next to the executable in BIN_DIR; fall back to the resolved
# binary artifact if a future toolchain stops doing that.
FRAMEWORKS="$APP/Contents/Frameworks"
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(find "$ROOT/.build" -type d -name Sparkle.framework -path '*macos*' 2>/dev/null | head -1)"
fi
[ -n "$SPARKLE_FW" ] && [ -d "$SPARKLE_FW" ] || {
  echo "ERROR: Sparkle.framework not found (looked in $BIN_DIR and .build/artifacts) — run 'swift build' first" >&2
  exit 1
}
echo "==> embedding Sparkle.framework from $SPARKLE_FW"
mkdir -p "$FRAMEWORKS"
# -R preserves the Versions/Current and top-level symlinks codesign expects in a framework bundle.
cp -R "$SPARKLE_FW" "$FRAMEWORKS/"

# ---- 5. code signature ----
# Sign the .app EXPLICITLY, never with `--deep`: the resource bundle has no Info.plist and so isn't a
# signable code bundle (`--deep` would fail on it), and Sparkle.framework's nested helpers must be sealed
# in a specific inside-out order (below). Signing each bundle without --deep signs its main Mach-O and
# seals plain resources, which is what we want.
#
# Hardened runtime + entitlements — the load-bearing subtlety once Sparkle.framework is embedded. Both
# depend on the signature carrying a real Team ID, which only a Developer ID identity has:
#   • Developer ID build: sign with `--options runtime` (notarization requires it) AND the full
#     entitlements. The app and the re-signed framework share one Team ID, so hardened-runtime *library
#     validation* lets the app load the framework with no extra entitlement (Sparkle's documented
#     same-certificate embedding), and that team owns the iCloud KVS container the entitlement names.
#   • Ad-hoc convenience build: sign WITHOUT hardened runtime AND WITHOUT entitlements. A team-less ad-hoc
#     signature breaks both: under hardened runtime, library validation aborts the app when it loads the
#     framework (and `disable-library-validation` can't rescue it — a restricted entitlement is ignored on
#     an ad-hoc signature); and AMFI SIGKILLs an ad-hoc app that *claims* the iCloud KVS entitlement it
#     can't own. This build is never notarized and can't use iCloud, so it loses nothing by dropping both
#     and stays launchable for local testing. (Before Sparkle there was no embedded framework, so the
#     library-validation half didn't bite.)
# A real Developer ID identity also adds `--timestamp` (Apple's secure TSA, mandatory for notarization);
# ad-hoc can't reach the TSA, so it omits it.
# `sign_runtime` seals one nested code object with the path-appropriate flags: hardened runtime +
# secure timestamp for Developer ID, a bare ad-hoc signature otherwise (see the rationale above).
sign_runtime() {
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

# Sign the embedded Sparkle.framework INSIDE-OUT: its own helpers (the Installer/Downloader XPC services,
# the Autoupdate tool, the Updater.app) are each a separate code object that must be sealed before the
# framework bundle that contains them, and the outer app is signed last (below).
echo "==> signing embedded Sparkle.framework (inside-out)"
FW_V="$FRAMEWORKS/Sparkle.framework/Versions/B"
for item in \
  "$FW_V/XPCServices/Installer.xpc" \
  "$FW_V/XPCServices/Downloader.xpc" \
  "$FW_V/Autoupdate" \
  "$FW_V/Updater.app"; do
  [ -e "$item" ] && sign_runtime "$item"
done
sign_runtime "$FRAMEWORKS/Sparkle.framework"

# ---- 5a. provisioning profile (restricted entitlements only) ----
# Two classes of entitlement behave differently. Hardened-runtime exceptions (`com.apple.security.cs.*`)
# take effect from the signature alone. Restricted capabilities (the `com.apple.developer.*` namespace:
# iCloud, App Groups, push, Sign in with Apple) are honoured by macOS ONLY when an embedded
# provisioning profile grants them, issued against an App ID that has the capability enabled.
#
# The profile must land BEFORE the outer codesign below, which seals it into the bundle.
#
# Omitting it fails silently and expensively: codesign, notarytool, stapler and Gatekeeper all pass,
# and the capability simply never works at runtime. Nothing in the verify step catches it. Hence the
# warning rather than a quiet skip. Ad-hoc builds are exempt because they sign without entitlements
# at all (see §5), and a restricted entitlement is ignored on an ad-hoc signature anyway.
# Parse the plist rather than grepping the raw file: the comment block documents the restricted
# entitlement it is NOT currently claiming, and a text grep counts that and warns on every build.
NEEDS_PROFILE="$(plutil -convert json -o - "$ENTITLEMENTS" 2>/dev/null | grep -c 'com\.apple\.developer\.' || true)"
if [ -n "$SIGN_IDENTITY" ]; then
  if [ -n "${PROVISION_PROFILE:-}" ]; then
    [ -f "$PROVISION_PROFILE" ] || { echo "ERROR: PROVISION_PROFILE not found: $PROVISION_PROFILE" >&2; exit 1; }
    # A profile for the wrong App ID is another silent failure: it embeds and signs cleanly while
    # granting nothing. A .provisionprofile is a CMS-signed plist, so `security cms -D` is what reads
    # it; a plain grep over the raw file would miss the payload. Both checks warn rather than abort,
    # since a false positive here shouldn't block a release.
    PROFILE_PLIST="$(security cms -D -i "$PROVISION_PROFILE" 2>/dev/null || true)"
    if [ -z "$PROFILE_PLIST" ]; then
      echo "   WARNING: could not decode $(basename "$PROVISION_PROFILE") (not a real .provisionprofile?)" >&2
    elif ! printf '%s' "$PROFILE_PLIST" | grep -q "$BUNDLE_ID"; then
      echo "   WARNING: $(basename "$PROVISION_PROFILE") never mentions $BUNDLE_ID → wrong App ID?" >&2
    fi
    echo "==> embedding provisioning profile: $(basename "$PROVISION_PROFILE")"
    cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  elif [ "$NEEDS_PROFILE" -gt 0 ]; then
    echo "   WARNING: $(basename "$ENTITLEMENTS") declares a restricted com.apple.developer.* entitlement," >&2
    echo "            but PROVISION_PROFILE is unset. THE APP WILL NOT LAUNCH: AMFI SIGKILLs a process" >&2
    echo "            claiming a restricted entitlement it can't prove it owns, at exec, before main()." >&2
    echo "            Signing, notarization and Gatekeeper all still pass, so this is the last chance to" >&2
    echo "            catch it. Finder will only say \"The application can't be opened.\"" >&2
  fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> signing $APP_NAME.app with Developer ID: $SIGN_IDENTITY (hardened runtime)"
  # The entitlements file lives with the release tooling, outside this repo. Signing without one is
  # correct here (the plist is an empty dict today), so its absence is a note rather than an error.
  # Point ENTITLEMENTS at that file when a real entitlement is restored, or the app claims nothing.
  if [ -f "$ENTITLEMENTS" ]; then
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
      --sign "$SIGN_IDENTITY" "$APP"
  else
    echo "   note: no entitlements file at $ENTITLEMENTS, signing without one"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  fi
else
  echo "==> ad-hoc signing $APP_NAME.app (no SIGN_IDENTITY — un-notarizable convenience build, no hardened runtime/entitlements)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --deep --verbose=2 "$APP" && echo "   signature verified"
codesign --display --entitlements - --verbose=2 "$APP" 2>/dev/null || true

# ---- 5b. notarize + staple the .app ----
# The notary service takes a .zip but `stapler` writes the ticket into the .app, so we submit a
# ditto-zip and staple the .app. Stapling the app (not just the .dmg) keeps it valid even after a
# user drags it out of the disk image. No-op when no notary credentials are set (header / notarize.sh).
if [ -f "$NOTARIZE_SH" ]; then
  APP_ZIP="$DIST/$APP_NAME.app.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  bash "$NOTARIZE_SH" --submit "$APP_ZIP" --staple "$APP"
  rm -f "$APP_ZIP"
fi

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
if [ -f "$NOTARIZE_SH" ]; then
  bash "$NOTARIZE_SH" --submit "$DMG" --staple "$DMG"
else
  echo "==> skipping notarization (no notarize.sh at $NOTARIZE_SH)"
  echo "    Releases are notarized by hand, with tooling kept outside this repo."
fi

echo
echo "==> DONE: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    Install: open the .dmg, drag $APP_NAME to Applications."
if [ -n "$SIGN_IDENTITY" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY:-}" ]; }; then
  echo "    Signed (Developer ID) + notarized + stapled — opens with no Gatekeeper workaround."
else
  echo "    Not notarized: first launch needs right-click → Open, or  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
fi
