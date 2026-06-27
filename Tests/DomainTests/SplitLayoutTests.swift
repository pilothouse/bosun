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

    // MARK: absolute extent clamp (vertical split)
    //
    // The vertical split sizes the terminal in points (stacked panes don't reflow with the sidebar
    // the way side-by-side ones do), so its bound is absolute — the pixel twin of `clampFraction`.

    func testExtentInRangeIsLeftUntouched() {
        XCTAssertEqual(SplitLayout.clampExtent(400, total: 1000), 400, accuracy: 1e-9)
    }

    func testExtentTooSmallClampsUpToTheTerminalFloor() {
        // 10px terminal — below the terminal floor; clamp up to minTerminalHeight.
        XCTAssertEqual(SplitLayout.clampExtent(10, total: 1000),
                       SplitLayout.minTerminalHeight, accuracy: 1e-9)
    }

    func testExtentTooLargeClampsDownSoTheDetailKeepsItsFloor() {
        // 990px terminal → 10px detail; clamp down so the detail keeps minDetailHeight.
        let clamped = SplitLayout.clampExtent(990, total: 1000)
        XCTAssertEqual(clamped, 1000 - SplitLayout.minDetailHeight, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(1000 - clamped, SplitLayout.minDetailHeight - 1e-9)
    }

    func testExtentOnLargeDisplayIsNotCappedAt760() {
        // Regression for #65: the old hard 760pt ceiling capped the terminal on 4K displays.
        let total = 2000.0
        XCTAssertEqual(SplitLayout.clampExtent(1500, total: total), 1500, accuracy: 1e-9)
        XCTAssertEqual(SplitLayout.clampExtent(1999, total: total),
                       total - SplitLayout.minDetailHeight, accuracy: 1e-9)
    }

    func testContainerTooShortForBothPanesFallsBackToEvenSplit() {
        // 200px can't give both panes their 120px floor; split evenly rather than pinning one side.
        XCTAssertEqual(SplitLayout.clampExtent(20, total: 200), 100, accuracy: 1e-9)
        XCTAssertEqual(SplitLayout.clampExtent(180, total: 200), 100, accuracy: 1e-9)
    }

    func testZeroOrNegativeTotalLeavesExtentUntouched() {
        // No geometry to clamp against yet (view not laid out) — pass the value through unharmed.
        XCTAssertEqual(SplitLayout.clampExtent(240, total: 0), 240, accuracy: 1e-9)
    }

    func testNeitherPaneCollapsesToZeroAcrossTotals() {
        // For any container height and any requested extent, both panes stay strictly positive.
        for total in stride(from: 50.0, through: 3000.0, by: 50) {
            for req in [-100.0, 0, 50, total / 2, total, total + 500] {
                let term = SplitLayout.clampExtent(req, total: total)
                XCTAssertGreaterThan(term, 0, "terminal collapsed at total=\(total) req=\(req)")
                XCTAssertGreaterThan(total - term, 0, "detail collapsed at total=\(total) req=\(req)")
            }
        }
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

    // MARK: seam position (#84)
    //
    // The seam is the divider line where the two panes meet, measured from the leading edge. The
    // view centers a fat hit-zone on this coordinate so the resize target straddles the seam rather
    // than being carved off one pane.

    func testSeamIsAtTheTerminalsFarEdgeWhenLeading() {
        // Terminal leading (top/left): it occupies [0, extent], so the seam sits at `extent`.
        XCTAssertEqual(SplitLayout.seamPosition(total: 1000, terminalExtent: 300, terminalLeading: true),
                       300, accuracy: 1e-9)
    }

    func testSeamIsOneExtentFromTheTrailingEdgeWhenTrailing() {
        // Terminal trailing (bottom/right, the default): the terminal occupies [total-extent, total],
        // so the seam sits one terminal-extent in from the trailing edge.
        XCTAssertEqual(SplitLayout.seamPosition(total: 1000, terminalExtent: 300, terminalLeading: false),
                       700, accuracy: 1e-9)
    }

    func testSeamIsSymmetricAcrossThePaneOrder() {
        // Flipping the pane order mirrors the seam about the container's midpoint, so the two
        // positions for a given extent always sum to the container size.
        let total = 1340.0, extent = 420.0
        let leading = SplitLayout.seamPosition(total: total, terminalExtent: extent, terminalLeading: true)
        let trailing = SplitLayout.seamPosition(total: total, terminalExtent: extent, terminalLeading: false)
        XCTAssertEqual(leading + trailing, total, accuracy: 1e-9)
    }
}
