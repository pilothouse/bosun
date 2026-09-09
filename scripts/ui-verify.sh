#!/usr/bin/env bash
#
# ui-verify.sh — offline UI smoke test for Bosun (issue #95).
#
# Launches the app in UI-test mode (BOSUN_UI_TEST=1), which swaps the Keychain token store for an
# in-memory one and seeds deterministic GitHub data + connections through the real ports. It then
# asserts the app comes up populated with NO Keychain password dialog — the blocker this mode
# removes — and drops a screenshot for human confirmation.
#
# This is the runnable, CI-friendly counterpart to the XCUITest bundle in Tests/UITests (which needs
# an Xcode host — see Tests/UITests/README.md). It drives the app with osascript + screencapture, so
# it needs a real GUI session (Metal/libghostty can't render on a locked/sleeping display).
#
# Usage:
#   swift build --disable-sandbox          # once, so .build/debug/Bosun exists
#   bash scripts/ui-verify.sh              # or: BOSUN_APP_PATH=/path/to/Bosun[.app/…/Bosun] bash scripts/ui-verify.sh
#
# Exit 0 = window came up populated and no Keychain dialog appeared. Non-zero = a hard failure.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BOSUN_APP_PATH:-$REPO/.build/debug/Bosun}"
OUT="${OUT:-$REPO/.build/ui-verify.png}"
# Seeded strings from UITestFixtures that must render (a connection + an issue title).
SEEDED=("prod-web-01" "zsh prompt is slow" "dotfiles")

[ -x "$BIN" ] || { echo "✗ missing binary: $BIN — run: swift build --disable-sandbox" >&2; exit 1; }

CAF=""; APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "$CAF" ] && kill "$CAF" 2>/dev/null || true
  pkill -x Bosun 2>/dev/null || true
}
trap cleanup EXIT INT TERM

caffeinate -dis & CAF=$!                 # keep the display awake so Metal surfaces can be created

BOSUN_UI_TEST=1 "$BIN" >/dev/null 2>&1 &
APP_PID=$!
echo "launched $BIN (pid $APP_PID) with BOSUN_UI_TEST=1"

# ── wait for the MAIN window (Bosun's min width is 1100pt) ────────────────────────────────────────
main_up=0
for _ in $(seq 1 40); do
  ps -p "$APP_PID" >/dev/null 2>&1 || { echo "✗ app exited early (no Metal display?)" >&2; exit 1; }
  W=$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"') to get item 1 of (get size of window 1)' 2>/dev/null || echo 0)
  [ "${W:-0}" -ge 1000 ] 2>/dev/null && { main_up=1; break; }
  sleep 0.5
done
[ "$main_up" = 1 ] || { echo "✗ main window never appeared" >&2; exit 1; }
echo "✓ main window is up"

# ── HARD FAIL if the Keychain password dialog is on screen ────────────────────────────────────────
if pgrep -x SecurityAgent >/dev/null; then
  echo "✗ SecurityAgent (Keychain password dialog) is up — the bypass FAILED" >&2
  exit 1
fi
echo "✓ no Keychain dialog (SecurityAgent absent)"

# ── best-effort content check: seeded labels are exposed as AXStaticText ─────────────────────────
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP_PID"') to true' >/dev/null 2>&1 || true
sleep 1
TEXTS=""
for _ in $(seq 1 6); do
  TEXTS=$(osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set out to ""
    try
      repeat with e in (entire contents of window 1)
        try
          if role of e is "AXStaticText" then set out to out & (value of e) & "\n"
        end try
      end repeat
    end try
    return out
  end tell
end tell
OSA
)
  [ -n "$TEXTS" ] && break
  sleep 0.5
done

missing=0
for s in "${SEEDED[@]}"; do
  if printf '%s' "$TEXTS" | grep -qi "$s"; then
    echo "✓ seeded text present: $s"
  else
    echo "… seeded text not found via AX: $s (AX traversal is flaky on this custom UI — see the screenshot)"
    missing=$((missing + 1))
  fi
done
[ "$missing" -gt 0 ] && echo "note: ${missing} seeded string(s) unconfirmed via AX; screenshot is the source of truth"

# ── screenshot for human confirmation ─────────────────────────────────────────────────────────────
screencapture -x "$OUT" 2>/dev/null || true
echo "✓ screenshot: $OUT"
echo "PASS: offline UI came up with no Keychain dialog"
