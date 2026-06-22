import XCTest
@testable import Domain

/// Contract tests for the pure org-following rules. They describe what `OrgFollowing` promises
/// outward — which orgs are visible (and in what order) given the user's saved choice, and how a
/// reorder moves an entry — not how it works inside. Don't edit a contract test to make an
/// implementation pass; if the contract is wrong, flag it.
final class OrgFollowingTests: XCTestCase {

    // MARK: visible

    func testVisibleWithoutCustomizationShowsEveryOrgInOrder() {
        let available = ["a", "b", "c"]
        XCTAssertEqual(OrgFollowing.visible(available: available, followed: nil), available,
                       "nil means never customized — show every available org as-is")
    }

    func testVisibleHonorsTheFollowedOrderAndSubset() {
        let available = ["a", "b", "c"]
        XCTAssertEqual(OrgFollowing.visible(available: available, followed: ["c", "a"]), ["c", "a"],
                       "only followed ids show, in the saved order")
    }

    func testVisibleDropsStaleFollowedIds() {
        // The viewer left org "x" since they last arranged the list.
        let available = ["a", "b"]
        XCTAssertEqual(OrgFollowing.visible(available: available, followed: ["x", "b", "a"]), ["b", "a"],
                       "ids no longer in `available` are dropped")
    }

    func testVisibleWithEmptyFollowedShowsNothing() {
        XCTAssertEqual(OrgFollowing.visible(available: ["a", "b"], followed: []), [],
                       "an explicit empty list means the user hid every org")
    }

    // MARK: reorder

    func testReorderMovesEntryDown() {
        XCTAssertEqual(OrgFollowing.reorder(["a", "b", "c"], from: 0, to: 2), ["b", "c", "a"])
    }

    func testReorderMovesEntryUp() {
        XCTAssertEqual(OrgFollowing.reorder(["a", "b", "c"], from: 2, to: 0), ["c", "a", "b"])
    }

    func testReorderIsANoOpWhenIndicesMatch() {
        XCTAssertEqual(OrgFollowing.reorder(["a", "b", "c"], from: 1, to: 1), ["a", "b", "c"])
    }

    func testReorderIsANoOpForOutOfRangeIndices() {
        XCTAssertEqual(OrgFollowing.reorder(["a", "b"], from: 0, to: 5), ["a", "b"])
        XCTAssertEqual(OrgFollowing.reorder(["a", "b"], from: -1, to: 1), ["a", "b"])
    }
}
