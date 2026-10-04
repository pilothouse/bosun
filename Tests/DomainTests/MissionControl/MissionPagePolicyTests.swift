import XCTest
@testable import Domain

/// Contract tests for `MissionPagePolicy`: grid shapes, Auto, and paging. The grid never scrolls —
/// sessions beyond one page go to the next page.
final class MissionPagePolicyTests: XCTestCase {

    /// A roomy area where every preset's tiles are usable (3×3 of 500×300 needs ~1516×916).
    private func shape(_ preset: MissionLayoutPreset, count: Int, width: Double = 1800, height: Double = 1000)
        -> MissionPageShape {
        MissionPagePolicy.shape(preset: preset, count: count, areaWidth: width, areaHeight: height,
                                minTileWidth: 500, minTileHeight: 300, gap: 8)
    }

    // MARK: Fixed presets

    func testFixedPresetIsUsedExactlyEvenWhenTilesWouldBeSmall() {
        let s = shape(.threeByThree, count: 2, width: 600, height: 400)
        XCTAssertEqual([s.columns, s.rows], [3, 3])
        XCTAssertEqual(s.perPage, 9, "page size follows the preset, not the session count")
    }

    // MARK: Auto

    func testAutoPicksTheSmallestPresetThatHoldsEverySession() {
        XCTAssertEqual(shape(.auto, count: 1).preset, .one)
        XCTAssertEqual(shape(.auto, count: 2).preset, .two)
        XCTAssertEqual(shape(.auto, count: 3).preset, .twoByTwo)
        XCTAssertEqual(shape(.auto, count: 5).preset, .threeByTwo)
        XCTAssertEqual(shape(.auto, count: 9).preset, .threeByThree)
    }

    func testAutoWithMoreSessionsThanFitUsesTheLargestUsablePresetAndPages() {
        XCTAssertEqual(shape(.auto, count: 13).preset, .threeByThree)
        // a laptop-sized area: 2×2 of 500×300 fits, 3×2 doesn't
        XCTAssertEqual(shape(.auto, count: 13, width: 1100, height: 700).preset, .twoByTwo)
    }

    func testAutoPrefersSideBySideInAWideArea() {
        XCTAssertEqual(shape(.auto, count: 2, width: 1800, height: 700).preset, .two)
    }

    func testAutoStacksTwoTilesInANarrowTallArea() {
        // 1×2 fits (500 wide, 2×300 tall) but 2×1 doesn't (2×500 + gap > 800)
        XCTAssertEqual(shape(.auto, count: 2, width: 800, height: 900).preset, .oneByTwo)
        XCTAssertEqual(shape(.auto, count: 13, width: 800, height: 900).preset, .oneByTwo,
                       "with more sessions than fit, the largest usable shape — here 2 stacked")
    }

    func testAutoFallsBackToOneTileWhenNothingIsUsable() {
        XCTAssertEqual(shape(.auto, count: 4, width: 300, height: 200).preset, .one)
    }

    func testAutoWithNoSessionsIsOneTile() {
        XCTAssertEqual(shape(.auto, count: 0).preset, .one)
    }

    // MARK: Slots

    func testSlotsFillRowByRowInThePresetShape() {
        let grid = shape(.threeByTwo, count: 6)
        XCTAssertEqual([MissionPagePolicy.slot(indexOnPage: 0, shape: grid)].map { [$0.column, $0.row] }, [[0, 0]])
        XCTAssertEqual([MissionPagePolicy.slot(indexOnPage: 4, shape: grid)].map { [$0.column, $0.row] }, [[1, 1]])
    }

    func testAPartialPageKeepsTheShapeAndLeavesEmptySlots() {
        let grid = shape(.threeByThree, count: 13)
        XCTAssertEqual(MissionPagePolicy.emptySlots(count: 4, shape: grid), 5)
        XCTAssertEqual(MissionPagePolicy.emptySlots(count: 9, shape: grid), 0)
        XCTAssertEqual(MissionPagePolicy.emptySlots(count: 0, shape: grid), 9)
    }

    // MARK: Paging

    func testPageCount() {
        XCTAssertEqual(MissionPagePolicy.pageCount(count: 0, perPage: 4), 1, "an empty grid is page 1 of 1")
        XCTAssertEqual(MissionPagePolicy.pageCount(count: 4, perPage: 4), 1)
        XCTAssertEqual(MissionPagePolicy.pageCount(count: 5, perPage: 4), 2)
        XCTAssertEqual(MissionPagePolicy.pageCount(count: 13, perPage: 6), 3)
    }

    func testPageOfIndex() {
        XCTAssertEqual(MissionPagePolicy.page(ofIndex: 0, perPage: 4), 0)
        XCTAssertEqual(MissionPagePolicy.page(ofIndex: 3, perPage: 4), 0)
        XCTAssertEqual(MissionPagePolicy.page(ofIndex: 4, perPage: 4), 1)
    }

    func testRangeOfTheLastPartialPage() {
        XCTAssertEqual(MissionPagePolicy.range(page: 2, perPage: 6, count: 13), 12..<13)
        XCTAssertEqual(MissionPagePolicy.range(page: 0, perPage: 6, count: 13), 0..<6)
        XCTAssertEqual(MissionPagePolicy.range(page: 5, perPage: 6, count: 13), 13..<13, "past the end is empty")
    }

    func testClampPageAfterSessionsClose() {
        XCTAssertEqual(MissionPagePolicy.clampPage(2, count: 7, perPage: 6), 1)
        XCTAssertEqual(MissionPagePolicy.clampPage(-1, count: 7, perPage: 6), 0)
        XCTAssertEqual(MissionPagePolicy.clampPage(3, count: 0, perPage: 6), 0)
    }

    // MARK: Stepping

    func testStepMovesThroughFixedPresetsAndStopsAtTheEnds() {
        XCTAssertEqual(MissionPagePolicy.step(from: .twoByTwo, by: 1), .threeByTwo)
        XCTAssertEqual(MissionPagePolicy.step(from: .twoByTwo, by: -1), .two)
        XCTAssertEqual(MissionPagePolicy.step(from: .one, by: 1), .oneByTwo)
        XCTAssertEqual(MissionPagePolicy.step(from: .threeByThree, by: 1), .threeByThree)
        XCTAssertEqual(MissionPagePolicy.step(from: .one, by: -1), .one)
    }
}
