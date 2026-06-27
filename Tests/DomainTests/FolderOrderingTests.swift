import XCTest
@testable import Domain

/// Contract tests for the pure folder-ordering rule — the flat-list reorder behind a folder drag.
/// They describe the promise (move one entry from a slot to another; a no-op or out-of-range move
/// changes nothing), not the implementation. Mirrors `OrgFollowingTests`.
final class FolderOrderingTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testMovesAnEntryToANewSlot() {
        XCTAssertEqual(FolderOrdering.reorder([a, b, c], from: 2, to: 0), [c, a, b])
        XCTAssertEqual(FolderOrdering.reorder([a, b, c], from: 0, to: 2), [b, c, a])
    }

    func testFromEqualsToLeavesTheListUnchanged() {
        XCTAssertEqual(FolderOrdering.reorder([a, b, c], from: 1, to: 1), [a, b, c])
    }

    func testOutOfRangeIndicesLeaveTheListUnchanged() {
        XCTAssertEqual(FolderOrdering.reorder([a, b, c], from: 0, to: 9), [a, b, c])
        XCTAssertEqual(FolderOrdering.reorder([a, b, c], from: -1, to: 1), [a, b, c])
        XCTAssertEqual(FolderOrdering.reorder([], from: 0, to: 0), [])
    }
}
