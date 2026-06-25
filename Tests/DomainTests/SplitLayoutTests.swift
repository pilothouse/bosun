import XCTest
@testable import Domain

/// Contract tests for the pure split-sizing rule used by the horizontal detail/terminal split.
/// They describe what `SplitLayout` promises outward — that a terminal-width fraction is clamped
/// so neither pane collapses, and that the pixel extent follows the clamped fraction — not how it
/// works inside. Works in `Double` so Domain stays free of CoreGraphics. Mirrors
/// `RepoVisibilityTests`. Don't edit a contract test to make an implementation pass; if the
/// contract is wrong, flag it.
final class SplitLayoutTests: XCTestCase {

    private let total: Double = 1000   // a roomy center column: minPane is comfortably honorable

    func testFractionInRangeIsLeftUntouched() {
        XCTAssertEqual(SplitLayout.clampFraction(0.5, total: total), 0.5, accuracy: 1e-9)
    }

    func testFractionTooSmallClampsUpSoTheTerminalKeepsMinPane() {
        // 0.01 * 1000 = 10px terminal — below minPane; clamp up to minPane/total.
        let clamped = SplitLayout.clampFraction(0.01, total: total)
        XCTAssertEqual(clamped, SplitLayout.minPane / total, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(clamped * total, SplitLayout.minPane - 1e-9)
    }

    func testFractionTooLargeClampsDownSoTheDetailKeepsMinPane() {
        // 0.99 * 1000 = 990px terminal → 10px detail; clamp down so the detail keeps minPane.
        let clamped = SplitLayout.clampFraction(0.99, total: total)
        XCTAssertEqual(clamped, 1 - SplitLayout.minPane / total, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual((1 - clamped) * total, SplitLayout.minPane - 1e-9)
    }

    func testContainerTooNarrowForBothPanesFallsBackToEvenSplit() {
        // 300px can't give both panes 220px; split evenly rather than pinning one side.
        XCTAssertEqual(SplitLayout.clampFraction(0.2, total: 300), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SplitLayout.clampFraction(0.9, total: 300), 0.5, accuracy: 1e-9)
    }

    func testZeroOrNegativeTotalIsLeftUntouched() {
        // No geometry to clamp against yet (view not laid out) — pass the value through unharmed.
        XCTAssertEqual(SplitLayout.clampFraction(0.42, total: 0), 0.42, accuracy: 1e-9)
    }

    func testTerminalExtentFollowsTheClampedFraction() {
        XCTAssertEqual(SplitLayout.terminalExtent(total: total, fraction: 0.5), 500, accuracy: 1e-9)
        // An out-of-range fraction is clamped before being turned into pixels.
        XCTAssertEqual(SplitLayout.terminalExtent(total: total, fraction: 0.99),
                       total - SplitLayout.minPane, accuracy: 1e-9)
    }

    func testDefaultFractionIsAUsableStartingShare() {
        XCTAssertGreaterThan(SplitLayout.defaultFraction, 0)
        XCTAssertLessThan(SplitLayout.defaultFraction, 1)
    }

    // MARK: drag sign

    func testDragGrowsTerminalWithTheDefaultTrailingOrder() {
        // Terminal trailing: grip on the top edge (vertical) / left edge (horizontal). Window space
        // is y-up, x-right, so dragging up (+y) or left (-x) must grow the terminal.
        XCTAssertEqual(SplitLayout.dragGrowsTerminal(axis: .vertical, terminalLeading: false), 1)
        XCTAssertEqual(SplitLayout.dragGrowsTerminal(axis: .horizontal, terminalLeading: false), -1)
    }

    func testDragSignFlipsWhenTheTerminalLeads() {
        // Terminal leading: grip on the opposite edge, so the same gesture shrinks rather than grows.
        XCTAssertEqual(SplitLayout.dragGrowsTerminal(axis: .vertical, terminalLeading: true), -1)
        XCTAssertEqual(SplitLayout.dragGrowsTerminal(axis: .horizontal, terminalLeading: true), 1)
    }
}
