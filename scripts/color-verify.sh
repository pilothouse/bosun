#!/usr/bin/env bash
#
# color-verify.sh — end-to-end GUI test for connection colors (issue #102), in every theme.
#
# For each theme it launches the app in UI-test mode (BOSUN_UI_TEST=1) and checks, from real pixels:
#   1. the seeded teal "build-box" row shows a colored leading stripe, and the uncolored "dotfiles"
#      row shows none (it looks exactly as it did before colors existed);
#   2. right-click "dotfiles" → Color ▸ Purple paints a purple stripe;
#   3. Color ▸ None removes it again;
#   4. after Color ▸ Purple → "Open in Terminal", the new terminal's background is tinted (it differs
#      from the plain local tab's background), and Mission Control is captured for a visual check.
# Screenshots land in .build/color-verify-<theme>.png and .build/color-verify-<theme>-mc.png — read
# them to judge readability over each tint.
#
# Pixel checks are RELATIVE (stripe vs. the row next to it, tinted vs. plain terminal), never exact hex:
# `screencapture` returns colors in the display's profile, so an sRGB #101318 panel can read #151920.
#
# Isolation: the run uses a copy of the binary, `.build/debug/BosunColorVerify`, so it gets its own
# UserDefaults domain (seeded per theme, deleted afterwards) and its own process name. Your real
# preferences and any running Bosun are never touched; only the process this script started is killed.
#
# Usage:
#   swift build --disable-sandbox           # once, so .build/debug/Bosun exists
#   bash scripts/color-verify.sh            # all four themes
#   THEMES="nord light" bash scripts/color-verify.sh
#
# Needs a real, unlocked GUI session plus Accessibility + Automation permission for the controlling
# terminal — same as ui-verify.sh / duplicate-verify.sh.
#
# Exit 0 = every check passed in every theme. Non-zero = a hard failure (the message says which).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_BIN="$REPO/.build/debug/Bosun"
BIN="$REPO/.build/debug/BosunColorVerify"
DOMAIN="BosunColorVerify"
THEMES="${THEMES:-operator carbon nord light}"
RIGHTCLICK="$REPO/.build/rightclick"
PIXELAVG="$REPO/.build/pixelavg"
MOUSEMOVE="$REPO/.build/mousemove"

# shellcheck source=lib/ax.sh
. "$REPO/scripts/lib/ax.sh"

[ -x "$SRC_BIN" ] || { echo "✗ missing binary: $SRC_BIN — run: swift build --disable-sandbox" >&2; exit 1; }

CAF=""; APP_PID=""
stop_app() {
  if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  APP_PID=""
}
cleanup() {
  stop_app
  [ -n "$CAF" ] && kill "$CAF" 2>/dev/null || true
  rm -f "$BIN"
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

pause() { python3 -c "import time; time.sleep($1)"; }

# ── helpers (compiled once, cached in .build/) ────────────────────────────────────────────────────
if [ ! -x "$RIGHTCLICK" ]; then
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
post(.mouseMoved, .left)
usleep(200_000)
post(.rightMouseDown, .right)
usleep(100_000)
post(.rightMouseUp, .right)
SWIFT
  swiftc -O "$SRC" -o "$RIGHTCLICK" 2>/dev/null || { echo "✗ could not compile the right-click helper" >&2; exit 1; }
  rm -f "$SRC"
fi
if [ ! -x "$PIXELAVG" ] || [ "${BASH_SOURCE[0]}" -nt "$PIXELAVG" ]; then
  SRC="$(mktemp -t pixelavg).swift"
  cat > "$SRC" <<'SWIFT'
import AppKit

// Average color of a PNG (a `screencapture -R` crop), printed as `rrggbb` in sRGB.
let args = CommandLine.arguments
guard args.count == 2, let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("usage: pixelavg <png>\n".utf8))
    exit(2)
}
var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        red += c.redComponent; green += c.greenComponent; blue += c.blueComponent; count += 1
    }
}
print(String(format: "%02x%02x%02x", Int((red / count * 255).rounded()),
             Int((green / count * 255).rounded()), Int((blue / count * 255).rounded())))
SWIFT
  swiftc -O "$SRC" -o "$PIXELAVG" 2>/dev/null || { echo "✗ could not compile the pixel helper" >&2; exit 1; }
  rm -f "$SRC"
fi

if [ ! -x "$MOUSEMOVE" ] || [ "${BASH_SOURCE[0]}" -nt "$MOUSEMOVE" ]; then
  SRC="$(mktemp -t mousemove).swift"
  cat > "$SRC" <<'SWIFT'
import CoreGraphics
import Foundation

// Move the cursor to a screen point (top-left origin) without clicking.
let argv = CommandLine.arguments
guard argv.count >= 3, let posX = Double(argv[1]), let posY = Double(argv[2]) else {
    FileHandle.standardError.write(Data("usage: mousemove <x> <y>\n".utf8))
    exit(2)
}
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: posX, y: posY),
        mouseButton: .left)?.post(tap: .cghidEventTap)
SWIFT
  swiftc -O "$SRC" -o "$MOUSEMOVE" 2>/dev/null || { echo "✗ could not compile the mouse-move helper" >&2; exit 1; }
  rm -f "$SRC"
fi

# park — move the cursor onto the window's title bar, so no row is drawn in its hover state while
# its pixels are sampled (a hovered row is lighter, which would skew a before/after comparison).
park() {
  local geom wx wy ww
  geom="$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"') to get {position, size} of window 1' | tr -d ',')"
  read -r wx wy ww _ <<<"$geom"
  "$MOUSEMOVE" "$((wx + ww / 2))" "$((wy + 12))"
  pause 0.3
}

# sample <x,y,w,h> — the average color of a screen rect (top-left origin, points) as rrggbb.
sample() {
  local png; png="$(mktemp -t colorverify).png"
  screencapture -x -o -R"$1" "$png"
  "$PIXELAVG" "$png"
  rm -f "$png"
}

# dist <hex> <hex> — summed per-channel distance (0…765).
dist() {
  python3 -c "a,b='$1','$2'; print(sum(abs(int(a[i:i+2],16)-int(b[i:i+2],16)) for i in (0,2,4)))"
}

# row_geom <label> — "railX,centerX,centerY" for the rail row labelled <label>: the left edge of the
# scroll area that holds it (where the leading stripe sits) and the label's centre. Retries while the
# accessibility tree fills in after launch or a rail rebuild; empty output means it never appeared.
row_geom() {
  local geom=""
  for _ in $(seq 1 10); do
    geom="$(row_geom_once "$1")"
    [ -n "$geom" ] && break
    pause 0.5
  done
  echo "$geom"
}

row_geom_once() {
  # Only the LEFTMOST scroll area counts — that's the rail. Other panes can carry the same text (the
  # org panel lists a "dotfiles" repo), and matching one of those would right-click the wrong view
  # and sample the wrong pixels.
  osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set best to ""
    set bestX to 100000
    repeat with sa in (scroll areas of window 1)
      set q to position of sa
      set sx to item 1 of q
      if sx < bestX then
        repeat with t in (static texts of sa)
          try
            if (value of t) is "$1" then
              set p to position of t
              set z to size of t
              set best to (sx as string) & "," & (((item 1 of p) + ((item 1 of z) div 2)) as string) & "," & (((item 2 of p) + ((item 2 of z) div 2)) as string)
              set bestX to sx
              exit repeat
            end if
          end try
        end repeat
      end if
    end repeat
    return best
  end tell
end tell
OSA
}

front() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
  pause 0.4
}

key() { osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1 || true; }

# menu_pick <label> <type-select…> — right-click a rail row, then type-select through its context
# menu. Each argument is typed then confirmed: "→" opens a submenu, anything else is a prefix.
menu_pick() {
  local geom cx cy
  geom="$(row_geom "$1")"; shift
  cx="$(echo "$geom" | cut -d, -f2)"; cy="$(echo "$geom" | cut -d, -f3)"
  front
  "$RIGHTCLICK" "$cx" "$cy" || { echo "SKIP: could not synthesise a right-click (grant Accessibility permission)" >&2; exit 2; }
  pause 0.8
  for step in "$@"; do
    if [ "$step" = "→" ]; then key "key code 124"; else key "keystroke \"$step\""; fi
    pause 0.4
  done
  [ -n "${DEBUG:-}" ] && screencapture -x "$REPO/.build/color-verify-debug-$THEME-$(date +%s).png"
  key "key code 36"   # Return
  pause 1.0
}

# stripe_check <label> <colored|plain> — compare the 2pt leading stripe with the row just right of it.
# A colored row's stripe is the solid swatch over a faint wash (far apart); a plain row has no stripe,
# so both samples are the same panel color.
stripe_check() {
  local geom rx cy stripe inner d
  geom="$(row_geom "$1")"
  [ -n "$geom" ] || { echo "✗ [$THEME] row '$1' not found in the accessibility tree" >&2; exit 1; }
  rx="$(echo "$geom" | cut -d, -f1)"; cy="$(echo "$geom" | cut -d, -f3)"
  front
  park
  # The scroll area reports its frame 1pt left of the row's first column, so start 1pt in.
  stripe="$(sample "$((rx + 1)),$((cy - 4)),2,12")"
  inner="$(sample "$((rx + 6)),$((cy - 4)),4,12")"
  d="$(dist "$stripe" "$inner")"
  if [ "$2" = colored ] && [ "$d" -lt 40 ]; then
    echo "✗ [$THEME] '$1' should show a color stripe (stripe $stripe vs row $inner, distance $d)" >&2; exit 1
  fi
  if [ "$2" = plain ] && [ "$d" -gt 8 ]; then
    echo "✗ [$THEME] '$1' should have no stripe (stripe $stripe vs row $inner, distance $d)" >&2; exit 1
  fi
  echo "✓ [$THEME] '$1' is $2 (stripe $stripe, row $inner)"
  LAST_STRIPE="$stripe"
}

caffeinate -dis & CAF=$!

for THEME in $THEMES; do
  stop_app
  cp "$SRC_BIN" "$BIN"
  # The tolerant Preferences decoder fills every other field with its default.
  defaults write "$DOMAIN" bosun.preferences -data "$(printf '{"themeKey":"%s"}' "$THEME" | xxd -p | tr -d '\n')"

  BOSUN_UI_TEST=1 "$BIN" >/dev/null 2>&1 &
  APP_PID=$!

  main_up=0
  for _ in $(seq 1 40); do
    ps -p "$APP_PID" >/dev/null 2>&1 || { echo "✗ app exited early (no Metal display?)" >&2; exit 1; }
    W=$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"') to get item 1 of (get size of window 1)' 2>/dev/null || echo 0)
    [ "${W:-0}" -ge 1000 ] 2>/dev/null && { main_up=1; break; }
    pause 0.5
  done
  [ "$main_up" = 1 ] || { echo "✗ [$THEME] main window never appeared" >&2; exit 1; }
  if pgrep -x SecurityAgent >/dev/null; then echo "✗ SecurityAgent (Keychain dialog) is up" >&2; exit 1; fi
  front
  pause 0.6
  echo "── $THEME (pid $APP_PID)"

  # The first synthetic click after the app activates is swallowed by window activation, so a
  # first right-click opens no menu and the type-select keys land in the shell instead. Prime it:
  # a throwaway right-click on a row, then Esc (which closes the menu if it did open).
  PRIME="$(row_geom "beacon")"
  [ -n "$PRIME" ] || { echo "✗ [$THEME] rail never appeared in the accessibility tree" >&2; exit 1; }
  "$RIGHTCLICK" "$(echo "$PRIME" | cut -d, -f2)" "$(echo "$PRIME" | cut -d, -f3)" || true
  pause 0.8
  key "key code 53"
  pause 0.4

  # 1. Seeded colors: build-box is teal, dotfiles has none.
  stripe_check "build-box" colored
  stripe_check "dotfiles" plain
  PLAIN_STRIPE="$LAST_STRIPE"

  # 2. Color ▸ Purple paints a purple stripe (red and blue channels above green).
  menu_pick "dotfiles" "col" "→" "pur"
  stripe_check "dotfiles" colored
  python3 -c "s='$LAST_STRIPE'; r,g,b=(int(s[i:i+2],16) for i in (0,2,4)); exit(0 if r>g and b>g else 1)" \
    || { echo "✗ [$THEME] dotfiles stripe $LAST_STRIPE is not purple" >&2; exit 1; }

  # 3. Color ▸ None removes it — back to the plain look.
  menu_pick "dotfiles" "col" "→" "non"
  stripe_check "dotfiles" plain
  [ "$(dist "$LAST_STRIPE" "$PLAIN_STRIPE")" -le 8 ] \
    || { echo "✗ [$THEME] 'None' did not restore the original row ($LAST_STRIPE vs $PLAIN_STRIPE)" >&2; exit 1; }

  # 4. A purple connection's terminal is tinted; the seeded local tab is not.
  menu_pick "dotfiles" "col" "→" "pur"
  menu_pick "dotfiles" "open"
  pause 1.0
  read -r WX WY WW WH <<<"$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"') to get {position, size} of window 1' | tr -d ',' )"
  TERM_RECT="$((WX + WW * 55 / 100)),$((WY + WH - 40)),60,20"
  front
  TINTED="$(sample "$TERM_RECT")"
  screencapture -x -o -R"$WX,$WY,$WW,$WH" "$REPO/.build/color-verify-$THEME.png"
  key 'keystroke "1" using {command down}'   # jump to tab 1, the plain local shell
  pause 0.8
  front
  PLAIN="$(sample "$TERM_RECT")"
  d="$(dist "$TINTED" "$PLAIN")"
  if [ "$d" -lt 4 ]; then
    echo "✗ [$THEME] purple terminal background $TINTED is not tinted vs plain $PLAIN (distance $d)" >&2; exit 1
  fi
  echo "✓ [$THEME] terminal background tinted ($TINTED vs plain $PLAIN)"

  # Mission Control, for the visual check of tile header/border/background.
  key 'keystroke "m" using {control down, command down}'
  pause 1.5
  front
  screencapture -x -o -R"$WX,$WY,$WW,$WH" "$REPO/.build/color-verify-$THEME-mc.png"
  echo "✓ [$THEME] screenshots: .build/color-verify-$THEME.png, .build/color-verify-$THEME-mc.png"
done

echo "PASS: connection colors render, change, clear and tint the terminal in: $THEMES"
