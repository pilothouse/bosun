import XCTest

/// End-to-end UI smoke test that launches the *running* Bosun app in offline UI-test mode
/// (`BOSUN_UI_TEST=1`) and asserts it comes up signed-in and populated with **no Keychain password
/// dialog** — the whole reason issue #95's mode exists. See `docs/ui-testing.md`.
///
/// ## This is not a SwiftPM test
/// XCUITest needs an Xcode UI-testing bundle + a scheme; `swift test` cannot host it. So this file is
/// *not* wired into `Package.swift` and never compiles under `swift build`/`swift test`. Run it from a
/// throwaway Xcode UI-testing target — see `Tests/UITests/README.md` for the exact steps, or use the
/// runnable, CI-friendly fallback `scripts/ui-verify.sh`, which performs the same launch-and-assert
/// with `osascript`/`screencapture`.
///
/// ## Accessibility reality of this app
/// Bosun draws its own UI over Metal and embeds a libghostty terminal. Its labels/rows *are* exposed
/// as `AXStaticText`, so the assertions below (seeded titles are present) work. But the custom
/// controls — the green "Comment" button, the org rows — are **not** `AXButton`s, and the terminal
/// surface holds keyboard focus, so `XCUIElement.tap()`/`typeText` on those won't behave like a
/// standard AppKit app. Interactive writes must go through coordinate-based events
/// (`XCUICoordinate.tap()` / `CGEvent`), which is why the primary win of this mode is a *populated,
/// dialog-free* launch that a human or a coordinate script can then drive.
final class BosunUITests: XCTestCase {

    /// The app bundle to launch. Build it first with `bash scripts/package-app.sh` (writes
    /// `dist/Bosun.app`); override with `BOSUN_APP_PATH` to point at another build.
    private var appURL: URL {
        if let override = ProcessInfo.processInfo.environment["BOSUN_APP_PATH"] {
            return URL(fileURLWithPath: override)
        }
        // Repo-relative default: this file sits at <repo>/Tests/UITests/BosunUITests.swift.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("dist/Bosun.app")
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication(url: appURL)
        app.launchEnvironment["BOSUN_UI_TEST"] = "1"
        return app
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// The app launches, shows its main window, and renders the seeded fixtures — with no sign-in
    /// sheet and no Keychain dialog blocking the run.
    func testLaunchesPopulatedWithoutKeychainDialog() {
        let app = makeApp()
        app.launch()

        // Main window is up (Bosun's default frame is 1340×880; the min is 1100×720).
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "main window never appeared")

        // Seeded content rendered — proof the fake API + in-memory cache hydrated the UI offline.
        // These strings come straight from `UITestFixtures` (Sources/Bosun/UITestSupport.swift).
        let seeded = ["atlas-api", "Stream large dispatch logs", "build-box"]
        for text in seeded {
            let element = app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", text, text)
            ).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "seeded text ‘\(text)’ not rendered")
        }

        // The device-flow sign-in sheet must NOT be present — the static token store already reports
        // a signed-in session, so no auth UI blocks the run.
        XCTAssertFalse(app.staticTexts["Sign in to GitHub"].exists, "unexpected sign-in sheet")

        app.terminate()
    }

    /// The issue #101 flow, end to end: right-click a connection row, pick "Duplicate", and the copy
    /// appears named after its original. Drives real events, so it asserts the whole chain —
    /// rail menu → `DuplicateConnectionUseCase` → `ConnectionNaming` → rail rebuild.
    ///
    /// Two properties of this app dictate the mechanics (both verified against the live AX tree):
    ///   * Rows are `AXStaticText`, not `AXButton`, so the row is *found* by its label but must be
    ///     *clicked* through a coordinate — hence `rightClick()` on the element's own coordinate,
    ///     which needs no hard-coded geometry.
    ///   * Bosun's contextual menus are **not** in the accessibility tree at all (with the menu open
    ///     the process still reports only its window and menu bar), so `app.menuItems["Duplicate"]`
    ///     finds nothing. The menu does take keyboard input, so the item is chosen by NSMenu
    ///     type-select: "dup" is a unique prefix among Connect / Edit… / Duplicate / Delete / Move to
    ///     folder, so this cannot quietly land on the wrong item.
    ///
    /// `scripts/duplicate-verify.sh` runs this same flow without an Xcode host and is the version
    /// that has actually been executed; keep the two in step.
    func testDuplicateConnectionFromContextMenu() {
        let app = makeApp()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "main window never appeared")

        // `build-box` is seeded in the "Lighthouse" folder and is not a favourite, so it renders
        // exactly once — no ambiguity about which row was hit (`UITestFixtures.connections`).
        let row = app.staticTexts["build-box"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded connection row never rendered")

        let copy = app.staticTexts["build-box (copy)"]
        XCTAssertFalse(copy.exists, "the copy must not exist before we make it")

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.typeText("dup\r")

        // A mis-selected item can't pass here: "Delete" would remove the row and "Edit…" would open
        // the sheet — neither produces a copy.
        XCTAssertTrue(copy.waitForExistence(timeout: 5),
                      "right-click → Duplicate did not create ‘build-box (copy)’")
        XCTAssertTrue(row.exists, "the original must survive its own duplication")

        app.terminate()
    }

    /// Example of the only reliable way to drive this custom UI: a coordinate tap. Kept minimal and
    /// tolerant — it documents the pattern (see the accessibility note above) rather than asserting a
    /// specific control, since exact geometry depends on the window frame.
    func testCoordinateInteractionPattern() throws {
        throw XCTSkip("Reference-only: coordinate interaction is geometry-dependent — see README.")
        // let app = makeApp(); app.launch()
        // let window = app.windows.firstMatch
        // XCTAssertTrue(window.waitForExistence(timeout: 20))
        // // Tap a normalized point inside the detail-pane composer, then type + submit (Return).
        // window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.46)).tap()
        // app.typeText("Offline UI-test comment\r")
    }
}
