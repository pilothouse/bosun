# Bosun UI tests

These drive the **running** app in offline UI-test mode (`BOSUN_UI_TEST=1`), which bypasses the
Keychain and seeds deterministic GitHub data + connections through the real ports. Because the
Keychain password dialog no longer blocks a scripted run, the app can be launched and asserted on
headlessly-ish (it still needs a real GUI session for Metal/libghostty). Background: `docs/ui-testing.md`.

There are two harnesses, by design:

## 1. `scripts/ui-verify.sh` — runnable today (recommended)

A shell smoke test that launches the app with the flag, asserts the main window comes up with **no
Keychain dialog**, best-effort-checks that seeded labels rendered, and drops a screenshot.

```sh
swift build --disable-sandbox
bash scripts/ui-verify.sh                 # → PASS + .build/ui-verify.png
```

No Xcode project needed. This is what CI / a quick local check should run.

## 2. `BosunUITests.swift` — the XCUITest bundle (attempted)

`XCUIApplication(url:)`-launches the packaged app with `BOSUN_UI_TEST=1` and asserts the window +
seeded static text, the "canonical" XCUITest form issue #95 asked to attempt.

**It is deliberately *not* in `Package.swift`.** SwiftPM has no UI-testing bundle, and `swift test`
cannot host XCUITest — so this file never compiles under `swift build`/`swift test` and can't break
the normal build. To actually run it you need a throwaway Xcode UI-testing target:

1. Package the app: `bash scripts/package-app.sh` → `dist/Bosun.app` (or set `BOSUN_APP_PATH`).
2. In Xcode: **File ▸ New ▸ Target… ▸ UI Testing Bundle** (in any macOS app/project shell), then add
   `Tests/UITests/BosunUITests.swift` to that target.
3. Run: `xcodebuild test -scheme <UITestScheme> -destination 'platform=macOS'`, or ⌘U in Xcode.

### Why the two-harness split — an accessibility caveat worth knowing

Bosun renders its own UI over Metal and embeds a libghostty terminal. Probing its accessibility tree
shows the trade-off XCUITest runs into here:

- **Labels/rows are exposed** as `AXStaticText` (≈100 elements in the main window), so *asserting*
  seeded content works in both harnesses.
- **Custom controls are not standard AX elements.** The green "Comment" button, the org/repo rows,
  and the status pickers are custom-drawn — they are **not** `AXButton`s, so `element.tap()` /
  `typeText` by identifier won't find them.
- **The terminal holds keyboard focus.** The embedded ghostty surface grabs first-responder at
  launch, so `typeText` lands in the shell unless a control is first focused by a real click.

Net: the dependable, high-value assertion is *"the app launches populated and dialog-free."* Driving
**writes** (post a comment, merge/close, edit) requires **coordinate-based** interaction —
`XCUICoordinate.tap()` at a normalized offset, or `CGEvent` clicks at computed points — not AX
queries. `testCoordinateInteractionPattern` sketches the pattern (skipped by default because exact
geometry depends on the window frame). This is a property of the app's custom rendering, independent
of `BOSUN_UI_TEST`.
