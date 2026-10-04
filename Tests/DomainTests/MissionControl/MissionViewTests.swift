import XCTest
@testable import Domain

/// Contract tests for Mission Control's persisted choices: `MissionView`, `MissionLayoutPreset` and
/// `MissionTrackerStyle`. Raw values are storage keys and must not drift.
final class MissionViewTests: XCTestCase {

    func testStorageKeysAreStable() {
        XCTAssertEqual(MissionView.allCases.map(\.rawValue), ["grid", "focus"])
        XCTAssertEqual(MissionLayoutPreset.allCases.map(\.rawValue), ["auto", "1x1", "1x2", "2x1", "2x2", "3x2", "3x3"])
        XCTAssertEqual(MissionTrackerStyle.allCases.map(\.rawValue), ["off", "list", "board"])
    }

    func testRetiredModeNamesFallBackToGrid() {
        for legacy in ["swarm", "wall", "board", "lanes", nil] {
            XCTAssertEqual(MissionView.stored(legacy), .grid)
        }
        XCTAssertEqual(MissionView.stored("focus"), .focus)
    }

    func testUnknownLayoutFallsBackToAuto() {
        XCTAssertEqual(MissionLayoutPreset.stored("16"), .auto)
        XCTAssertEqual(MissionLayoutPreset.stored("3x2"), .threeByTwo)
    }

    func testShortcutDigitsMapToViews() {
        XCTAssertEqual(MissionView.forShortcut(1), .grid)
        XCTAssertEqual(MissionView.forShortcut(2), .focus)
        XCTAssertNil(MissionView.forShortcut(3))
    }

    func testFixedPresetsAreOrderedByTileCount() {
        let counts = MissionLayoutPreset.fixed.compactMap { $0.shape.map { $0.columns * $0.rows } }
        XCTAssertEqual(counts, [1, 2, 2, 4, 6, 9])
        XCTAssertNil(MissionLayoutPreset.auto.shape)
    }

    func testTrackerToggleRemembersTheLastVisibleStyle() {
        XCTAssertEqual(MissionTrackerStyle.board.toggled(lastVisible: .board), .off)
        XCTAssertEqual(MissionTrackerStyle.off.toggled(lastVisible: .board), .board)
        XCTAssertEqual(MissionTrackerStyle.off.toggled(lastVisible: .off), .list)
    }
}
