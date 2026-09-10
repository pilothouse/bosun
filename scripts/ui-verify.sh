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
# The seeded-content check used to walk `entire contents of window 1`, which returns an EMPTY list on
# this hierarchy — so it never found anything, always printed "not found via AX", and never failed.
# It now uses the traversal that works (scripts/lib/ax.sh) and is a HARD assertion: "populated" is
# half of what this script claims to prove, so it should be able to fail.
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

# shellcheck source=lib/ax.sh
. "$REPO/scripts/lib/ax.sh"

# One seeded string per pane, so a half-hydrated UI fails: a connection (the rail, via
# ConnectionStore), the selected issue's title (the detail pane, via the fake GitHub API) and a repo
# (the org panel, via the seeded cache). All three must be VISIBLE in the default launch state —
# `UITestFixtures` also contains e.g. `atlas-api`, which belongs to an org the app doesn't have
# selected at launch and so never renders. Assert what's on screen, not what's in the fixture file.
SEEDED=("build-box" "zsh prompt is slow over mosh" "scratchpad")

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

# ── HARD content check: the seeded labels are rendered ────────────────────────────────────────────
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP_PID"') to true' >/dev/null 2>&1 || true
sleep 1
TEXTS=""
for _ in $(seq 1 8); do
  TEXTS=$(ax_texts "$APP_PID")
  [ -n "$TEXTS" ] && break
  sleep 0.5
done
[ -n "$TEXTS" ] || { echo "✗ no labels readable from the accessibility tree at all" >&2; exit 1; }

missing=0
for s in "${SEEDED[@]}"; do
  if printf '%s' "$TEXTS" | grep -qiF "$s"; then
    echo "✓ seeded text present: $s"
  else
    echo "✗ seeded text MISSING: $s" >&2
    missing=$((missing + 1))
  fi
done

# ── screenshot for human confirmation ─────────────────────────────────────────────────────────────
screencapture -x "$OUT" 2>/dev/null || true
echo "✓ screenshot: $OUT"

[ "$missing" -eq 0 ] || { echo "✗ ${missing} seeded string(s) never rendered — see $OUT" >&2; exit 1; }
echo "PASS: offline UI came up populated, with no Keychain dialog"
