#!/usr/bin/env bash
#
# activity-verify.sh — end-to-end GUI test for Mission Control "Highlight activity" (issue #103), in
# every theme.
#
# For each theme it launches the app in UI-test mode (BOSUN_UI_TEST=1) straight into Mission Control
# (2×2 grid, tracker off, highlight ON, busy shell hook ON), opens two more local tabs (3 tiles: A, B,
# C), and checks from real pixels and the accessibility tree:
#   1. working: C runs `sleep 6` while A has focus → the bar reads "Working 1" and C's outline turns
#      accent (blue-ish) — far from B's plain outline;
#   2. done: when the sleep ends, C gets a green outline and a green check in its header, and the bar
#      reads "Working 0" again (done is not "working");
#   3. dim: B (idle, unfocused) is dimmed — its terminal text reads clearly different from A's (focused,
#      never dimmed);
#   4. done clears on focus: focusing C removes the green check;
#   5. toggle off (options ▾ → Highlight activity): B is no longer dimmed, and a new `sleep` in C ends
#      with a plain outline — Mission Control looks exactly as before #103.
# Screenshots land in .build/activity-verify-<theme>-{working,done,off}.png — read them to judge the look.
#
# Pixel checks are RELATIVE (tile A vs tile C, before vs after), never exact hex: `screencapture`
# returns colors in the display's profile.
#
# Isolation: the run uses a copy of the binary, `.build/debug/BosunActivityVerify`, so it gets its own
# UserDefaults domain (seeded per theme, deleted afterwards) and its own process name. Your real
# preferences and any running Bosun are never touched; keystrokes are sent only while this script's
# process is frontmost, and only that process is killed.
#
# Usage:
#   swift build --disable-sandbox           # once, so .build/debug/Bosun exists
#   bash scripts/activity-verify.sh         # all four themes
#   THEMES="nord light" bash scripts/activity-verify.sh
#
# Needs a real, unlocked GUI session, a zsh login shell ($SHELL) for the busy hook, plus Accessibility
# + Automation permission for the controlling terminal — same as color-verify.sh.
#
# Exit 0 = every check passed in every theme. Non-zero = a hard failure (the message says which).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_BIN="$REPO/.build/debug/Bosun"
BIN="$REPO/.build/debug/BosunActivityVerify"
DOMAIN="BosunActivityVerify"
THEMES="${THEMES:-operator carbon nord light}"
LEFTCLICK="$REPO/.build/leftclick"
PIXELAVG="$REPO/.build/pixelavg"

[ -x "$SRC_BIN" ] || { echo "✗ missing binary: $SRC_BIN — run: swift build --disable-sandbox" >&2; exit 1; }
case "${SHELL:-}" in *zsh) ;; *) echo "✗ the busy hook needs a zsh \$SHELL (got '${SHELL:-}')" >&2; exit 1 ;; esac

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
fail() {
  echo "✗ [$THEME] $*" >&2
  [ -n "${WX:-}" ] && screencapture -x -o -R"$WX,$WY,$WW,$WH" "$REPO/.build/activity-verify-$THEME-fail.png" \
    && echo "  screenshot: .build/activity-verify-$THEME-fail.png" >&2
  exit 1
}

# ── helpers (compiled once, cached in .build/) ────────────────────────────────────────────────────
if [ ! -x "$LEFTCLICK" ]; then
  SRC="$(mktemp -t leftclick).swift"
  cat > "$SRC" <<'SWIFT'
import CoreGraphics
import Foundation

// Synthesise a left click at a screen point (top-left origin, matching AX `position`).
let argv = CommandLine.arguments
guard argv.count >= 3, let posX = Double(argv[1]), let posY = Double(argv[2]) else {
    FileHandle.standardError.write(Data("usage: leftclick <x> <y>\n".utf8))
    exit(2)
}
let point = CGPoint(x: posX, y: posY)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
post(.mouseMoved)
usleep(200_000)
post(.leftMouseDown)
usleep(100_000)
post(.leftMouseUp)
SWIFT
  swiftc -O "$SRC" -o "$LEFTCLICK" 2>/dev/null || { echo "✗ could not compile the click helper" >&2; exit 1; }
  rm -f "$SRC"
fi
if [ ! -x "$PIXELAVG" ]; then
  echo "✗ missing $PIXELAVG — run scripts/color-verify.sh once (it builds the shared pixel helper)" >&2
  exit 1
fi

# sample <x,y,w,h> — the average color of a screen rect (top-left origin, points) as rrggbb.
sample() {
  local png; png="$(mktemp -t activityverify).png"
  screencapture -x -o -R"$1" "$png"
  "$PIXELAVG" "$png"
  rm -f "$png"
}

# dist <hex> <hex> — summed per-channel distance (0…765).
dist() {
  python3 -c "a,b='$1','$2'; print(sum(abs(int(a[i:i+2],16)-int(b[i:i+2],16)) for i in (0,2,4)))"
}

# channel <hex> <r|g|b> — one channel as 0…255.
channel() {
  python3 -c "s='$1'; print(int(s[{'r':0,'g':2,'b':4}['$2']:][:2],16))"
}

front() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
  pause 0.4
}

# key <applescript> — send a keystroke ONLY while this script's app is frontmost, so it can never land
# in another app (or in a Bosun you are using).
key() {
  front
  local frontmost
  frontmost="$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null || echo 0)"
  [ "$frontmost" = "$APP_PID" ] || fail "another app is frontmost (pid $frontmost); refusing to type"
  osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1 || true
}

run_in_focused() { key "keystroke \"$1\""; key "key code 36"; }
focus_next() { key 'key code 124 using {control down, command down}'; pause 0.6; }      # ⌃⌘→
focus_previous() { key 'key code 123 using {control down, command down}'; pause 0.6; }  # ⌃⌘←

# texts — every window-level label as "value|x|y|w|h", one per line, in view order.
texts() {
  osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set out to ""
    repeat with t in (static texts of window 1)
      try
        set p to position of t
        set z to size of t
        set out to out & (value of t) & "|" & (item 1 of p) & "|" & (item 2 of p) & "|" & (item 1 of z) & "|" & (item 2 of z) & linefeed
      end try
    end repeat
    return out
  end tell
end tell
OSA
}

has_text() { texts | cut -d'|' -f1 | grep -qx "$1"; }

# tiles — "minX headerMidY maxX" per tile, sorted top-left → bottom-right. A tile header lays out its
# close "×" before its title, so the label right after each "×" is that tile's title, drawn 20pt in
# from the tile's left edge; the "×" sits 20pt in from the right edge.
tiles() {
  texts | python3 -c '
import sys
rows = [l.rstrip("\n").split("|") for l in sys.stdin if l.count("|") == 4]
out = []
for i, r in enumerate(rows[:-1]):
    if r[0] == "×":
        t = rows[i + 1]
        out.append((int(t[2]) + int(t[4]) // 2, int(t[1]) - 20, int(r[1]) + 20))
for y, x, mx in sorted(out):
    print(x, y, mx)'
}

caffeinate -dis & CAF=$!

for THEME in $THEMES; do
  stop_app
  cp "$SRC_BIN" "$BIN"
  # The tolerant Preferences decoder fills every other field with its default.
  PREFS='{"themeKey":"%s","workspaceLayout":"missionControl","missionLayout":"2x2","missionTracker":"off","missionHighlightActivity":true,"terminalBusySpinner":true}'
  defaults write "$DOMAIN" bosun.preferences -data "$(printf "$PREFS" "$THEME" | xxd -p | tr -d '\n')"

  BOSUN_UI_TEST=1 "$BIN" >/dev/null 2>&1 &
  APP_PID=$!

  main_up=0
  for _ in $(seq 1 40); do
    ps -p "$APP_PID" >/dev/null 2>&1 || { echo "✗ app exited early (no Metal display?)" >&2; exit 1; }
    W=$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"') to get item 1 of (get size of window 1)' 2>/dev/null || echo 0)
    [ "${W:-0}" -ge 1000 ] 2>/dev/null && { main_up=1; break; }
    pause 0.5
  done
  [ "$main_up" = 1 ] || fail "main window never appeared"
  if pgrep -x SecurityAgent >/dev/null; then fail "SecurityAgent (Keychain dialog) is up"; fi
  echo "── $THEME (pid $APP_PID)"
  pause 1.5

  # Three tiles: the seeded tab plus two new local tabs (⌘T is ghostty's new-tab keybind).
  key 'keystroke "t" using {command down}'; pause 1.5
  key 'keystroke "t" using {command down}'; pause 2.0
  read -r WX WY WW WH <<<"$(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"') to get {position, size} of window 1' | tr -d ',')"
  TILES="$(tiles)"
  [ "$(echo "$TILES" | grep -c .)" -ge 3 ] || fail "expected 3 tiles, found: $(echo "$TILES" | tr '\n' ';')"
  read -r AX AY _ <<<"$(echo "$TILES" | sed -n 1p)"
  read -r BX BY _ <<<"$(echo "$TILES" | sed -n 2p)"
  read -r CX CY _ <<<"$(echo "$TILES" | sed -n 3p)"
  # Probes: the left outline (2pt, mid-body), the header activity badge, and the first lines of text.
  border() { echo "$1,$(($2 + 60)),2,40"; }
  badge() { echo "$(($1 + 6)),$(($2 - 4)),9,8"; }
  textrect() { echo "$(($1 + 4)),$(($2 + 16)),300,60"; }

  # Roles. W (working) is C, the newest tab, which has focus now. L (looking) is A, where focus moves
  # while W runs. Q (quiet) is B, idle and unfocused. The launch tab (A) is not used for the run: it is
  # created before the saved preferences load, so it never gets the busy shell hook.
  WX_="$CX"; WY_="$CY"; LX="$AX"; LY="$AY"; QX="$BX"; QY="$BY"

  run_in_focused "sleep 6"
  START=$(date +%s)
  focus_next                                   # C → A (wraps)
  pause 1.5

  # 1. working
  has_text "Working 1" || fail "bar should read 'Working 1' while W runs: $(texts | cut -d'|' -f1 | grep Working)"
  W_BORDER="$(sample "$(border "$WX_" "$WY_")")"; Q_BORDER="$(sample "$(border "$QX" "$QY")")"
  d="$(dist "$W_BORDER" "$Q_BORDER")"
  [ "$d" -ge 40 ] || fail "working outline $W_BORDER should differ from plain $Q_BORDER (distance $d)"
  [ "$(( $(channel "$W_BORDER" b) - $(channel "$W_BORDER" r) ))" -gt "$(( $(channel "$Q_BORDER" b) - $(channel "$Q_BORDER" r) ))" ] \
    || fail "working outline $W_BORDER should be bluer than plain $Q_BORDER"
  screencapture -x -o -R"$WX,$WY,$WW,$WH" "$REPO/.build/activity-verify-$THEME-working.png"
  echo "✓ [$THEME] working: 'Working 1', accent outline ($W_BORDER vs plain $Q_BORDER)"

  # 3. dim — Q (idle, unfocused) vs L (focused): the same kind of fresh shell, so the text reads alike
  #    unless one is dimmed.
  L_TEXT="$(sample "$(textrect "$LX" "$LY")")"; Q_TEXT_DIM="$(sample "$(textrect "$QX" "$QY")")"
  d="$(dist "$L_TEXT" "$Q_TEXT_DIM")"
  [ "$d" -ge 6 ] || fail "idle tile should be dimmed vs the focused one (text $Q_TEXT_DIM vs $L_TEXT, distance $d)"
  echo "✓ [$THEME] dim: idle tile differs from focused tile (distance $d)"

  # 2. done
  while [ $(( $(date +%s) - START )) -lt 8 ]; do pause 0.5; done
  has_text "Working 0" || fail "bar should read 'Working 0' once the run finished"
  W_BORDER="$(sample "$(border "$WX_" "$WY_")")"; W_BADGE="$(sample "$(badge "$WX_" "$WY_")")"
  python3 -c "s='$W_BORDER'; r,g,b=(int(s[i:i+2],16) for i in (0,2,4)); exit(0 if g>r+20 and g>b else 1)" \
    || fail "done outline $W_BORDER is not green"
  python3 -c "s='$W_BADGE'; r,g,b=(int(s[i:i+2],16) for i in (0,2,4)); exit(0 if g>r+20 and g>b else 1)" \
    || fail "done header badge $W_BADGE is not a green check"
  screencapture -x -o -R"$WX,$WY,$WW,$WH" "$REPO/.build/activity-verify-$THEME-done.png"
  echo "✓ [$THEME] done: green outline $W_BORDER, green check $W_BADGE, 'Working 0'"

  # 4. done clears on focus (A → C, wrapping back)
  focus_previous
  W_BADGE="$(sample "$(badge "$WX_" "$WY_")")"
  python3 -c "s='$W_BADGE'; r,g,b=(int(s[i:i+2],16) for i in (0,2,4)); exit(1 if g>r+20 and g>b else 0)" \
    || fail "the green check should clear once the tile has focus (badge $W_BADGE)"
  echo "✓ [$THEME] focus clears done (badge $W_BADGE)"

  # 5. toggle off: options ▾ → Highlight activity. The first synthetic click after activation can be
  #    swallowed, so prime with a harmless click on the status line first.
  OPT="$(texts | awk -F'|' '$1=="options ▾"{print $2+$4/2, $3+$5/2}')"
  [ -n "$OPT" ] || fail "options pill not found"
  STATUS="$(texts | awk -F'|' '$1 ~ /^Sessions? /{print $2+$4/2, $3+$5/2}')"
  front
  # shellcheck disable=SC2086
  "$LEFTCLICK" $STATUS || true; pause 0.5
  # shellcheck disable=SC2086
  "$LEFTCLICK" $OPT; pause 0.8
  key 'keystroke "hig"'; pause 0.4
  key "key code 36"; pause 1.0
  Q_TEXT="$(sample "$(textrect "$QX" "$QY")")"
  d="$(dist "$Q_TEXT" "$Q_TEXT_DIM")"
  [ "$d" -ge 6 ] || fail "turning the highlight off should undim the idle tile (text $Q_TEXT vs dimmed $Q_TEXT_DIM, distance $d)"
  # W still has focus (the menu hands it back). Run again there, look away, and let it finish.
  run_in_focused "sleep 2"
  focus_next
  pause 4
  W_BORDER="$(sample "$(border "$WX_" "$WY_")")"; Q_BORDER="$(sample "$(border "$QX" "$QY")")"
  d="$(dist "$W_BORDER" "$Q_BORDER")"
  [ "$d" -le 12 ] || fail "with highlight off, the finished tile's outline $W_BORDER should match plain $Q_BORDER (distance $d)"
  screencapture -x -o -R"$WX,$WY,$WW,$WH" "$REPO/.build/activity-verify-$THEME-off.png"
  echo "✓ [$THEME] off: idle tile undimmed (distance $(dist "$Q_TEXT" "$Q_TEXT_DIM")), finished tile plain ($W_BORDER vs $Q_BORDER)"
  echo "✓ [$THEME] screenshots: .build/activity-verify-$THEME-{working,done,off}.png"
done

echo "PASS: Mission Control activity highlight (working, done, dim, focus-clear, off) in: $THEMES"
