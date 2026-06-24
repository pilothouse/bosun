#!/usr/bin/env bash
# Notarize one artifact with Apple and staple the resulting ticket onto another.
#
# Apple's notary service accepts a .zip, .dmg, or .pkg and returns a ticket once the
# notarized contents pass its checks. `stapler` then writes that ticket *into* the
# artifact so Gatekeeper can approve it offline. The two paths differ on purpose:
# you can't staple a .zip — for a .app you SUBMIT a zip of it but STAPLE the .app.
# package-app.sh calls this twice:
#   1. submit a ditto-zip of Bosun.app, staple Bosun.app   (so the app is valid even
#      after a user drags it out of the .dmg)
#   2. submit Bosun.dmg,                  staple Bosun.dmg  (so the download itself opens)
#
# Credentials (pick ONE; checked in this order):
#   NOTARY_PROFILE   name of a `xcrun notarytool store-credentials` keychain profile
#                    (the convenient local path — credentials live in the Keychain)
#   NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER
#                    an App Store Connect API key: NOTARY_KEY is the path to the .p8,
#                    NOTARY_KEY_ID its Key ID, NOTARY_ISSUER the issuer UUID (the CI path)
#
# If NEITHER is configured this script is a deliberate no-op (exit 0): the caller has
# already produced a hardened-runtime-signed build, it just won't be notarized. That
# keeps the pre-v1 convenience build (and any environment without Apple secrets, e.g.
# this repo's fork PRs) working unchanged.
#
# Usage:
#   scripts/notarize.sh --submit <path.zip|path.dmg> --staple <path.app|path.dmg>
set -euo pipefail

SUBMIT=""
STAPLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --submit) SUBMIT="$2"; shift 2 ;;
    --staple) STAPLE="$2"; shift 2 ;;
    *) echo "notarize.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$SUBMIT" ] && [ -n "$STAPLE" ] || { echo "notarize.sh: --submit and --staple are required" >&2; exit 2; }
[ -e "$SUBMIT" ] || { echo "notarize.sh: submit path not found: $SUBMIT" >&2; exit 2; }
[ -e "$STAPLE" ] || { echo "notarize.sh: staple path not found: $STAPLE" >&2; exit 2; }

# ---- resolve credentials into notarytool's auth flags ----
AUTH=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  echo "==> notarize: no credentials (NOTARY_PROFILE or NOTARY_KEY/_ID/_ISSUER) — skipping"
  echo "    '$STAPLE' is signed but NOT notarized; Gatekeeper will quarantine downloads."
  exit 0
fi

echo "==> notarize: submitting $(basename "$SUBMIT") (waiting for Apple)…"
# --wait blocks until Apple finishes. Note: notarytool exits non-zero only on a transport/auth
# error — a *rejected* submission ("status: Invalid") still exits 0. So we capture the output, then
# fail unless the status is "Accepted", pulling the per-issue log either way (its one-line summary
# rarely says *why* it failed). `|| true` keeps `set -e` from killing us before we can inspect it.
SUBMIT_OUT="$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait 2>&1)" || true
echo "$SUBMIT_OUT"
if ! printf '%s\n' "$SUBMIT_OUT" | grep -q "status: Accepted"; then
  echo "notarize: submission was not Accepted — see output above" >&2
  REQ_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/^[[:space:]]*id:/ {print $2; exit}')"
  if [ -n "$REQ_ID" ]; then
    echo "==> notarize: fetching log for $REQ_ID" >&2
    xcrun notarytool log "$REQ_ID" "${AUTH[@]}" >&2 || true
  fi
  exit 1
fi

echo "==> notarize: stapling ticket onto $(basename "$STAPLE")"
xcrun stapler staple "$STAPLE"
xcrun stapler validate "$STAPLE" && echo "   staple validated"
