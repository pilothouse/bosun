import XCTest
@testable import Domain

/// Contract tests for `SettingsPaneLayout` — the pure geometry that resizes the Settings window when
/// the user switches panes (#88). The promise: the window adopts the incoming pane's size plus a
/// constant chrome (titlebar + toolbar) height, while its TOP edge stays pinned so the toolbar doesn't
/// jump as the body grows or shrinks. No AppKit — the App layer converts `Frame` ↔ `NSRect`.
/// Don't edit a contract test to make an implementation pass — if the contract is wrong, flag it.
final class SettingsPaneLayoutTests: XCTestCase {

    func testAdoptsPaneSizePlusChromeAndPinsTheTopEdge() {
        // 600-tall window at y=200 (top edge = 800), 52pt chrome, switching to a shorter/narrower pane.
        let current = SettingsPaneLayout.Frame(minX: 100, minY: 200, width: 520, height: 600)
        let result = SettingsPaneLayout.windowFrame(current: current, paneWidth: 480, paneHeight: 300, chromeHeight: 52)

        XCTAssertEqual(result.height, 352)        // 300 pane + 52 chrome
        XCTAssertEqual(result.width, 480)         // adopts the pane's width
        XCTAssertEqual(result.maxY, current.maxY) // top edge stays at 800
        XCTAssertEqual(result.minY, 448)          // 800 − 352
        XCTAssertEqual(result.minX, current.minX) // left edge unchanged
    }

    func testGrowingPaneDropsTheBottomButKeepsTheTop() {
        let current = SettingsPaneLayout.Frame(minX: 0, minY: 500, width: 400, height: 200) // top edge = 700
        let result = SettingsPaneLayout.windowFrame(current: current, paneWidth: 400, paneHeight: 360, chromeHeight: 40)

        XCTAssertEqual(result.height, 400)
        XCTAssertEqual(result.maxY, 700)          // unchanged
        XCTAssertEqual(result.minY, 300)          // 700 − 400; the window extends downward
    }

    func testIdentityWhenThePaneAlreadyFits() {
        let current = SettingsPaneLayout.Frame(minX: 12, minY: 34, width: 500, height: 392)
        let result = SettingsPaneLayout.windowFrame(current: current, paneWidth: 500, paneHeight: 340, chromeHeight: 52)

        XCTAssertEqual(result, current)
    }
}
