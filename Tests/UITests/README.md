# Bosun UI tests

These drive the **running** app in offline UI-test mode (`BOSUN_UI_TEST=1`), which bypasses the
Keychain and seeds deterministic GitHub data + connections through the real ports. Because the
Keychain password dialog no longer blocks a scripted run, the app can be launched and asserted on
headlessly-ish (it still needs a real GUI session for Metal/libghostty). Background: `docs/ui-testing.md`.

There are three harnesses, by design:

## 1. `scripts/ui-verify.sh` — runnable today (recommended)

A shell smoke test that launches the app with the flag and asserts the main window comes up with
**no Keychain dialog** *and* populated — one seeded label per pane (rail / detail / org panel) must
have rendered — then drops a screenshot.

```sh
swift build --disable-sandbox
bash scripts/ui-verify.sh                 # → PASS + .build/ui-verify.png
```

No Xcode project needed. This is what CI / a quick local check should run.

## 1b. `scripts/duplicate-verify.sh` — a real interaction, runnable today

The same idea pushed one step further: it drives an actual **write** through the UI. Launches the
app, finds the seeded `build-box` connection row in the accessibility tree, **right-clicks** it,
picks `Duplicate` from the context menu, and asserts a `build-box (copy)` row appeared (issue #101).

```sh
swift build --disable-sandbox
bash scripts/duplicate-verify.sh          # → PASS + .build/duplicate-verify.png
```

It needs two things AppleScript can't do alone, and both are worth knowing before writing another
interaction test — see the caveat below for why:

- **A right-click.** System Events' `click` has no secondary-button form, so the script compiles a
  ~15-line `CGEvent` helper with `swiftc` on first run (cached in `.build/`). No Homebrew dependency.
- **A menu selection by name.** Done with NSMenu type-select (`dup` + Return), not a fixed number of
  arrow-downs, so it can't silently land on the wrong item.

Same prerequisites as `ui-verify.sh` (real GUI session, Accessibility + Automation permission).

## 2. `BosunUITests.swift` — the XCUITest bundle (attempted)

`XCUIApplication(url:)`-launches the packaged app with `BOSUN_UI_TEST=1` and asserts the window +
seeded static text, the "canonical" XCUITest form issue #95 asked to attempt. It also carries
`testDuplicateConnectionFromContextMenu` — the XCUITest spelling of what `duplicate-verify.sh` runs
(right-click a row → Duplicate → assert the copy). Keep the two in step; the script is the one that
can actually be executed here.

**It is deliberately *not* in `Package.swift`.** SwiftPM has no UI-testing bundle, and `swift test`
cannot host XCUITest — so this file never compiles under `swift build`/`swift test` and can't break
the normal build. To actually run it you need a throwaway Xcode UI-testing target:

1. Package the app: `bash scripts/package-app.sh` → `dist/Bosun.app` (or set `BOSUN_APP_PATH`).
2. In Xcode: **File ▸ New ▸ Target… ▸ UI Testing Bundle** (in any macOS app/project shell), then add
   `Tests/UITests/BosunUITests.swift` to that target.
3. Run: `xcodebuild test -scheme <UITestScheme> -destination 'platform=macOS'`, or ⌘U in Xcode.

### Why the harnesses split — an accessibility caveat worth knowing

Bosun renders its own UI over Metal and embeds a libghostty terminal. Probing its accessibility tree
shows the trade-off XCUITest runs into here:

- **Labels/rows are exposed** as `AXStaticText` (≈100 elements in the main window), so *asserting*
  seeded content works in both harnesses.
- **Custom controls are not standard AX elements.** The green "Comment" button, the org/repo rows,
  and the status pickers are custom-drawn — they are **not** `AXButton`s, so `element.tap()` /
  `typeText` by identifier won't find them.
- **The terminal holds keyboard focus.** The embedded ghostty surface grabs first-responder at
  launch, so `typeText` lands in the shell unless a control is first focused by a real click.
- **Contextual menus are not in the AX tree at all.** Even with a right-click menu open on screen,
  the process reports only its window and menu bar — `count menus` is `0`, so
  `click menu item "Duplicate"` / `app.menuItems["Duplicate"]` have nothing to address. (The *main*
  menu bar is exposed normally; pop-up menus are not.) They do accept keyboard input, so select an
  item with NSMenu **type-select** — type a unique prefix, then Return.
- **`entire contents of window 1` returns an empty list.** AppleScript's recursion doesn't descend
  this view hierarchy. A traversal written that way finds nothing and every assertion built on it
  passes vacuously — which is what `ui-verify.sh`'s seeded-text check did until #101 (it printed
  "not found via AX" for labels that were plainly on screen, and never failed). The labels *are*
  reachable one level down: as direct `static text` children of the window and of each of its
  `scroll area`s (the connection rail is one of them).

  Both scripts now share that traversal via **`scripts/lib/ax.sh`** (`ax_texts`, `ax_center`) — use
  it rather than hand-rolling another `entire contents` walk.

- **Assert what's on screen, not what's in the fixture file.** `UITestFixtures` seeds more than the
  default launch state shows: `atlas-api` and `Stream large dispatch logs` belong to an org the app
  doesn't have selected at launch, so they never render. They sat in `ui-verify.sh`'s expected list
  for exactly as long as the check was silently broken.

Net: driving **writes** (post a comment, merge/close, edit, duplicate) requires **coordinate-based**
interaction — `XCUICoordinate.rightClick()`/`.tap()`, or `CGEvent` clicks at computed points — not AX
queries. But the coordinate need not be hard-coded: locate the target's label in the AX tree and
click *its* rect, which is what `duplicate-verify.sh` and `testDuplicateConnectionFromContextMenu` do.
`testCoordinateInteractionPattern` sketches the cruder fixed-offset form (skipped by default because
exact geometry depends on the window frame). All of this is a property of the app's custom rendering,
independent of `BOSUN_UI_TEST`.
