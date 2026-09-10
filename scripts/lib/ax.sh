# shellcheck shell=bash
#
# ax.sh — accessibility helpers shared by the GUI verification scripts
# (scripts/ui-verify.sh, scripts/duplicate-verify.sh). Source it; don't execute it.
#
# Bosun draws its UI over Metal, and two properties of the resulting accessibility tree are
# non-obvious enough to be worth stating once, here, instead of rediscovering them per script:
#
#   1. `entire contents of window 1` returns an EMPTY list. AppleScript's recursion does not descend
#      this view hierarchy at all — a traversal written that way silently finds nothing and every
#      assertion built on it passes vacuously. (That is exactly what happened to ui-verify.sh's
#      seeded-text check until #101.)
#   2. The labels ARE reachable one level down: as direct `static text` children of the window and of
#      each of its `scroll area`s. The connection rail, the org/repo panel and the detail pane are
#      each one of those scroll areas.
#
# A third property matters when *driving* the UI rather than reading it: rows are `AXStaticText`, not
# `AXButton`, so they can be located but not clicked through AX — use `ax_center` to get a point and
# click it with a synthesised event. Contextual menus aren't in the tree at all; drive them with
# NSMenu type-select. See Tests/UITests/README.md.

# ax_texts <pid> — every rendered label in the main window, one per line.
ax_texts() {
  osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell (first process whose unix id is $1)
    set out to ""
    repeat with t in (static texts of window 1)
      try
        set out to out & (value of t) & linefeed
      end try
    end repeat
    repeat with sa in (scroll areas of window 1)
      repeat with t in (static texts of sa)
        try
          set out to out & (value of t) & linefeed
        end try
      end repeat
    end repeat
    return out
  end tell
end tell
OSA
}

# ax_center <pid> <label> — "x,y" screen centre of the label whose value is exactly <label>
# (top-left origin, matching CGEvent). Empty output means it isn't on screen.
ax_center() {
  osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell (first process whose unix id is $1)
    repeat with sa in (scroll areas of window 1)
      repeat with t in (static texts of sa)
        try
          if (value of t) is "$2" then
            set p to position of t
            set z to size of t
            return (((item 1 of p) + ((item 1 of z) div 2)) as string) & "," & (((item 2 of p) + ((item 2 of z) div 2)) as string)
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
OSA
}
