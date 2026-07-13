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
        let seeded = ["dotfiles", "zsh prompt is slow", "prod-web-01"]
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
