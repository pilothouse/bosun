#!/usr/bin/env bash
# Set up Developer ID signing + Apple notarization for a CI job — or NO-OP cleanly without it.
#
# This is the shared signing setup used by BOTH .github/workflows/ci.yml (the master-branch
# .dmg artifact) and .github/workflows/release.yml (the tagged GitHub Release). It lives in one
# file so the security-sensitive cert/keychain handling has a single source of truth and can't
# drift between two workflow copies.
#
# It reads six secrets from the environment (the caller's `env:` block maps them from
# `secrets.*`):
#   MACOS_CERTIFICATE_P12_BASE64   base64 of the Developer ID Application cert (.p12)
#   MACOS_CERTIFICATE_PASSWORD     the .p12 export password
#   MACOS_SIGN_IDENTITY            e.g. "Developer ID Application: Name (TEAMID)"
#   APPLE_API_KEY_P8_BASE64        base64 of the App Store Connect API key (.p8)
#   APPLE_API_KEY_ID               the API key's Key ID
#   APPLE_API_ISSUER_ID            the API key's issuer UUID
#
# When MACOS_CERTIFICATE_P12_BASE64 is empty (forks, or before the maintainer adds the secrets)
# it exits 0 without touching anything, so package-app.sh falls back to an ad-hoc build and CI
# never breaks. Otherwise it imports the cert into a throwaway keychain, writes the API key to a
# temp file, and appends the env vars package-app.sh + notarize.sh read (SIGN_IDENTITY, NOTARY_*,
# SIGNING_KEYCHAIN) to $GITHUB_ENV so later steps inherit them.
#
# CI-specific: requires $GITHUB_ENV and $RUNNER_TEMP (set by GitHub Actions). See docs/signing.md
# for how to produce each secret. Tear down with: security delete-keychain "$SIGNING_KEYCHAIN".
set -euo pipefail

if [ -z "${MACOS_CERTIFICATE_P12_BASE64:-}" ]; then
  echo "No signing secrets configured — package-app.sh will ad-hoc sign (un-notarized)."
  exit 0
fi

# Import the Developer ID Application cert into a temporary keychain that we delete after.
KEYCHAIN="$RUNNER_TEMP/bosun-signing.keychain-db"
KEYCHAIN_PW="$(uuidgen)"
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"     # auto-lock after 6h
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"

CERT_P12="$RUNNER_TEMP/cert.p12"
echo "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$CERT_P12"
security import "$CERT_P12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
rm -f "$CERT_P12"
# Let codesign use the private key without an interactive prompt on the headless runner.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
# Prepend our keychain to the search list (preserving the existing entries) so codesign finds it.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

# App Store Connect API key for notarytool (notarize.sh reads NOTARY_KEY/_ID/_ISSUER).
API_KEY_P8="$RUNNER_TEMP/asc_api_key.p8"
echo "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$API_KEY_P8"

{
  echo "SIGN_IDENTITY=$MACOS_SIGN_IDENTITY"
  echo "NOTARY_KEY=$API_KEY_P8"
  echo "NOTARY_KEY_ID=$APPLE_API_KEY_ID"
  echo "NOTARY_ISSUER=$APPLE_API_ISSUER_ID"
  echo "SIGNING_KEYCHAIN=$KEYCHAIN"
} >> "$GITHUB_ENV"
echo "Configured Developer ID signing for: $MACOS_SIGN_IDENTITY"
