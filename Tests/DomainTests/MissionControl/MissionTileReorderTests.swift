import XCTest
@testable import Domain

/// Contract tests for `MissionTileReorder`: dropping a tile moves its tab into the target's slot.
final class MissionTileReorderTests: XCTestCase {

    private func apply(_ order: [String], _ dragged: String, _ target: String) -> [String] {
        var tabs = TerminalTabs<String>()
        order.forEach { tabs.open($0) }
        if let move = MissionTileReorder.tabMove(tabOrder: tabs.ids, draggedTab: dragged, targetTab: target) {
            tabs.reorder(from: move.from, to: move.to)
        }
        return tabs.ids
    }

    func testDroppingLaterTakesTheTargetSlot() {
        XCTAssertEqual(apply(["a", "b", "c"], "a", "c"), ["b", "c", "a"])
    }

    func testDroppingEarlierLandsBeforeTheTarget() {
        XCTAssertEqual(apply(["a", "b", "c"], "c", "a"), ["c", "a", "b"])
    }

    func testDroppingOnAPaneOfTheSameTabMovesNothing() {
        XCTAssertNil(MissionTileReorder.tabMove(tabOrder: ["a", "b"], draggedTab: "a", targetTab: "a"))
    }

    func testUnknownTabMovesNothing() {
        XCTAssertNil(MissionTileReorder.tabMove(tabOrder: ["a", "b"], draggedTab: "z", targetTab: "a"))
    }
}
