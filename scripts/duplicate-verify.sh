#!/usr/bin/env bash
#
# duplicate-verify.sh — end-to-end GUI test for "Duplicate connection" (issue #101).
#
# Launches the app in UI-test mode (BOSUN_UI_TEST=1), finds the seeded `build-box` connection row,
# RIGHT-CLICKS it, picks "Duplicate" from the context menu, and asserts a `build-box (copy)` row
# appeared. This is the one flow the issue describes, driven for real rather than asserted on
# indirectly.
#
# Why it can't be pure AppleScript, unlike scripts/ui-verify.sh:
#   * Bosun draws its rail over Metal. Rows are exposed as AXStaticText (so they can be *found* and
#     their screen rect read) but they are not AXButtons, so `click` on the element does nothing.
#   * System Events' `click` verb has no secondary-button form at all.
# So the row's centre is located through the accessibility tree — no hard-coded geometry — and the
# right-click itself is synthesised with a tiny CGEvent helper compiled on first run. The NSMenu that
# opens *is* ordinary AppKit and fully AX-exposed, so the menu item is picked by title.
#
# Usage:
#   swift build --disable-sandbox           # once, so .build/debug/Bosun exists
#   bash scripts/duplicate-verify.sh        # or: BOSUN_APP_PATH=/path/to/Bosun[.app/…/Bosun]
#
# Needs a real, unlocked GUI session (Metal/libghostty can't render on a locked display) plus
# Accessibility + Automation permission for the controlling terminal — same as ui-verify.sh.
#
# Exit 0 = the copy was created through the real context menu. Non-zero = a hard failure.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BOSUN_APP_PATH:-$REPO/.build/debug/Bosun}"
OUT="${OUT:-$REPO/.build/duplicate-verify.png}"
HELPER="$REPO/.build/rightclick"

# shellcheck source=lib/ax.sh
. "$REPO/scripts/lib/ax.sh"     # ax_texts / ax_center — see that file for the AX traps they dodge

# The connection to duplicate, and the name the Domain rule must produce for its copy.
# `build-box` is seeded by UITestFixtures, sits alone in the "Lighthouse" folder and is NOT a
# favourite — so its name renders exactly once in the rail and the assertion is unambiguous.
ROW="build-box"
COPY="build-box (copy)"

[ -x "$BIN" ] || { echo "✗ missing binary: $BIN — run: swift build --disable-sandbox" >&2; exit 1; }

CAF=""; APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "$CAF" ] && kill "$CAF" 2>/dev/null || true
  pkill -x Bosun 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── build the right-click helper (cached; only input is this script) ──────────────────────────────
if [ ! -x "$HELPER" ] || [ "${BASH_SOURCE[0]}" -nt "$HELPER" ]; then
  SRC="$(mktemp -t rightclick).swift"
  cat > "$SRC" <<'SWIFT'
import CoreGraphics
import Foundation

// Synthesise a right-click at a screen point (top-left origin, matching AX `position`).
let argv = CommandLine.arguments
guard argv.count >= 3, let posX = Double(argv[1]), let posY = Double(argv[2]) else {
    FileHandle.standardError.write(Data("usage: rightclick <x> <y>\n".utf8))
    exit(2)
}
let point = CGPoint(x: posX, y: posY)
func post(_ type: CGEventType, _ button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
        .post(tap: .cghidEventTap)
}
post(.mouseMoved, .left)          // let the row take hover/first-responder state first
usleep(200_000)
post(.rightMouseDown, .right)
usleep(100_000)
post(.rightMouseUp, .right)
SWIFT
  swiftc -O "$SRC" -o "$HELPER" 2>/dev/null || { echo "✗ could not compile the CGEvent helper" >&2; exit 1; }
  rm -f "$SRC"
  echo "✓ built right-click helper"
fi

caffeinate -dis & CAF=$!

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

if pgrep -x SecurityAgent >/dev/null; then
  echo "✗ SecurityAgent (Keychain password dialog) is up — the bypass FAILED" >&2
  exit 1
fi
echo "✓ no Keychain dialog"

osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP_PID"') to true' >/dev/null 2>&1 || true
sleep 1

# ── locate the row's centre from the accessibility tree (no hard-coded geometry) ──────────────────
CENTER=""
for _ in $(seq 1 8); do
  CENTER=$(ax_center "$APP_PID" "$ROW")
  [ -n "$CENTER" ] && break
  sleep 0.5
done
[ -n "$CENTER" ] || { echo "✗ connection row '$ROW' not found in the accessibility tree" >&2; exit 1; }
CX="${CENTER%%,*}"; CY="${CENTER##*,}"
echo "✓ found row '$ROW' at ${CX},${CY}"

# Guard against a false pass: the copy must not already exist.
if ax_texts "$APP_PID" | grep -qF "$COPY"; then
  echo "✗ '$COPY' was already on screen before the duplicate — fixtures changed?" >&2
  exit 1
fi

# ── right-click it ────────────────────────────────────────────────────────────────────────────────
"$HELPER" "$CX" "$CY" || { echo "SKIP: could not synthesise a right-click (grant Accessibility permission)" >&2; exit 2; }
sleep 1

# ── pick "Duplicate" from the open context menu ───────────────────────────────────────────────────
# Bosun's contextual menus are NOT in the accessibility tree — with the menu open, the process still
# reports only AXWindow + AXMenuBar and `count menus` is 0, so `click menu item "Duplicate"` has
# nothing to address. (Its main menu bar *is* exposed; pop-up menus are not.) The menu does accept
# keyboard input, so it's driven by NSMenu's type-select: typing a prefix highlights the matching
# item BY NAME. "dup" is unique among Connect / Edit… / Duplicate / Delete / Move to folder, so this
# can't quietly land on the wrong item the way a fixed number of arrow-downs could.
osascript -e 'tell application "System Events" to keystroke "dup"' >/dev/null 2>&1 || true
sleep 0.4
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1 || true   # Return
echo "✓ selected 'Duplicate' by name (type-select)"

# ── assert the copy appeared ──────────────────────────────────────────────────────────────────────
found=0
for _ in $(seq 1 12); do
  if ax_texts "$APP_PID" | grep -qF "$COPY"; then found=1; break; fi
  sleep 0.5
done

screencapture -x "$OUT" 2>/dev/null || true

if [ "$found" != 1 ]; then
  # This also catches a mis-selected menu item: "Delete" would remove the row, "Edit…" would open
  # the sheet — neither produces the copy, so a wrong pick fails here rather than passing quietly.
  echo "✗ '$COPY' never appeared in the rail — see $OUT" >&2
  exit 1
fi
echo "✓ '$COPY' rendered in the rail"
echo "✓ screenshot: $OUT"
echo "PASS: right-click → Duplicate created '$COPY'"
