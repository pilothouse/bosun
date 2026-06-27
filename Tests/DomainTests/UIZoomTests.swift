import XCTest
@testable import Domain

/// Contract tests for `UIZoom`, the pure UI/terminal zoom rule persisted in
/// `Preferences.uiZoomPercent`. They describe what it promises outward — its 100% default, its
/// `[50, 200]%` range in 5% steps, the clamped in/out/reset transitions, and the percent→scale
/// conversion the App layer multiplies fonts and layout geometry by — not how it works inside.
/// Mirrors `SplitAxisTests`/`SplitLayoutTests`. Don't edit a contract test to make an
/// implementation pass; if the contract is wrong, flag it.
final class UIZoomTests: XCTestCase {

    func testDefaultIsHundredPercent() {
        XCTAssertEqual(UIZoom.default.percent, 100, "an upgrade starts at 1:1 zoom, unchanged")
        XCTAssertEqual(UIZoom.default.scale, 1.0)
    }

    func testScaleIsPercentOverOneHundred() {
        XCTAssertEqual(UIZoom(percent: 150).scale, 1.5)
        XCTAssertEqual(UIZoom(percent: 50).scale, 0.5)
        XCTAssertEqual(UIZoom(percent: 200).scale, 2.0)
    }

    func testZoomInStepsUpByFive() {
        XCTAssertEqual(UIZoom.default.zoomedIn().percent, 105)
        XCTAssertEqual(UIZoom(percent: 105).zoomedIn().percent, 110)
    }

    func testZoomOutStepsDownByFive() {
        XCTAssertEqual(UIZoom.default.zoomedOut().percent, 95)
        XCTAssertEqual(UIZoom(percent: 95).zoomedOut().percent, 90)
    }

    func testZoomInClampsAtMaximum() {
        XCTAssertEqual(UIZoom.maxPercent, 200)
        XCTAssertEqual(UIZoom(percent: 200).zoomedIn().percent, 200,
                       "zoom in stops at the maximum rather than overshooting")
    }

    func testZoomOutClampsAtMinimum() {
        XCTAssertEqual(UIZoom.minPercent, 50)
        XCTAssertEqual(UIZoom(percent: 50).zoomedOut().percent, 50,
                       "zoom out stops at the minimum rather than going to an unreadable size")
    }

    func testResetReturnsToHundred() {
        XCTAssertEqual(UIZoom(percent: 170).reset().percent, 100)
        XCTAssertEqual(UIZoom(percent: 50).reset(), UIZoom.default)
    }

    func testInitClampsOutOfRange() {
        XCTAssertEqual(UIZoom(percent: 500).percent, 200, "a corrupt high value clamps to the max")
        XCTAssertEqual(UIZoom(percent: -10).percent, 50, "a corrupt low value clamps to the min")
    }

    func testInitSnapsToFiveStep() {
        // The persisted percent is always on the 5% grid (it only ever comes from these
        // transitions), but a stray off-grid value snaps to the nearest step rather than yielding
        // an odd scale.
        XCTAssertEqual(UIZoom(percent: 92).percent, 90)
        XCTAssertEqual(UIZoom(percent: 93).percent, 95)
        XCTAssertEqual(UIZoom(percent: 94).percent, 95)
    }

    func testCodableRoundTrip() throws {
        for percent in stride(from: 50, through: 200, by: 5) {
            let zoom = UIZoom(percent: percent)
            let data = try JSONEncoder().encode(zoom)
            XCTAssertEqual(try JSONDecoder().decode(UIZoom.self, from: data), zoom)
        }
    }
}
