import XCTest
@testable import Domain

/// Contract tests for the pure connection-ordering rule. They describe what `ConnectionOrdering`
/// promises outward — that a drag reorders one section's members among the slots they already
/// hold in the global list, leaving every other connection fixed — not how it works inside. The
/// rule takes plain `UUID`s so Domain needn't know the App's presentation type. Don't edit a
/// contract test to make an implementation pass; if the contract is wrong, flag it.
final class ConnectionOrderingTests: XCTestCase {

    // A fixed pool of ids so the assertions read by position. `all` is the global order; the
    // sections below are subsets of it (in their global-relative order, as the rail derives them).
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    func testReordersWithinASectionThatSpansTheWholeList() {
        let all = [a, b, c]
        let result = ConnectionOrdering.reorder(all, sectionIDs: [a, b, c], from: 2, to: 0)
        XCTAssertEqual(result, [c, a, b], "moving the last entry to the front reorders the list")
    }

    func testNonSectionIdsKeepTheirAbsoluteSlots() {
        // Global order [a, b, c, d, e]; the SSH section is [a, c, e] (b and d are folders).
        // Move the section's first member (a) to its end. The section becomes [c, e, a]; it must
        // be spliced back over a/c/e's slots only — b and d never move.
        let all = [a, b, c, d, e]
        let result = ConnectionOrdering.reorder(all, sectionIDs: [a, c, e], from: 0, to: 2)
        XCTAssertEqual(result, [c, b, e, d, a],
                       "section members reorder among slots 0/2/4; non-members b@1 and d@3 stay put")
    }

    func testMovingPastANonMemberDoesNotMoveTheNonMember() {
        // Section [a, e]; move e before a. Only a/e's slots (0 and 4) are rewritten.
        let all = [a, b, c, d, e]
        let result = ConnectionOrdering.reorder(all, sectionIDs: [a, e], from: 1, to: 0)
        XCTAssertEqual(result, [e, b, c, d, a])
    }

    func testFromEqualsToLeavesTheListUnchanged() {
        let all = [a, b, c, d, e]
        XCTAssertEqual(ConnectionOrdering.reorder(all, sectionIDs: [a, c, e], from: 1, to: 1), all)
    }

    func testOutOfRangeIndicesLeaveTheListUnchanged() {
        let all = [a, b, c]
        XCTAssertEqual(ConnectionOrdering.reorder(all, sectionIDs: [a, b], from: 0, to: 5), all)
        XCTAssertEqual(ConnectionOrdering.reorder(all, sectionIDs: [a, b], from: -1, to: 1), all)
        XCTAssertEqual(ConnectionOrdering.reorder(all, sectionIDs: [], from: 0, to: 0), all)
    }
}
