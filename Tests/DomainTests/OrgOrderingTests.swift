import XCTest
@testable import Domain

/// Contract tests for the pure org-ordering rule. They describe what `OrgOrdering` promises
/// outward — the order organizations take for a given mode and direction — not how it works inside.
/// The rule operates on `(name, activity)` projections so Domain needn't know the App's presentation
/// `Org` type; here a tiny local fixture supplies those. `.manual` preserves the incoming
/// (`OrgFollowing` drag) order; `.byName`/`.byActivity` honor the direction. Don't edit a contract
/// test to make an implementation pass; if the contract is wrong, flag it. Mirrors
/// `RepoOrderingTests` and `ItemSortingTests`.
final class OrgOrderingTests: XCTestCase {

    private struct O { let name: String; let activity: Int }

    private func order(_ orgs: [O], by mode: OrgOrderingMode, ascending: Bool) -> [String] {
        OrgOrdering.order(orgs, by: mode, ascending: ascending,
                          name: \.name, activity: \.activity).map(\.name)
    }

    // MARK: manual

    func testManualPreservesInputOrderRegardlessOfDirection() {
        // Manual is the user's drag order; the rule must not touch it, and direction is ignored.
        let orgs = [O(name: "gamma", activity: 0), O(name: "Alpha", activity: 9), O(name: "beta", activity: 1)]
        XCTAssertEqual(order(orgs, by: .manual, ascending: true), ["gamma", "Alpha", "beta"])
        XCTAssertEqual(order(orgs, by: .manual, ascending: false), ["gamma", "Alpha", "beta"],
                       "manual ignores direction — the drag order stands")
    }

    // MARK: byName

    func testByNameAscendingIsCaseInsensitiveAToZ() {
        let orgs = [O(name: "beta", activity: 1), O(name: "Alpha", activity: 9), O(name: "gamma", activity: 0)]
        XCTAssertEqual(order(orgs, by: .byName, ascending: true), ["Alpha", "beta", "gamma"],
                       "name order ignores case and ignores activity")
    }

    func testByNameDescendingReverses() {
        let orgs = [O(name: "beta", activity: 1), O(name: "Alpha", activity: 9), O(name: "gamma", activity: 0)]
        XCTAssertEqual(order(orgs, by: .byName, ascending: false), ["gamma", "beta", "Alpha"])
    }

    // MARK: byActivity

    func testByActivityAscendingIsLeastActiveFirst() {
        let orgs = [O(name: "busy", activity: 40), O(name: "quiet", activity: 2), O(name: "mid", activity: 7)]
        XCTAssertEqual(order(orgs, by: .byActivity, ascending: true), ["quiet", "mid", "busy"])
    }

    func testByActivityDescendingIsMostActiveFirst() {
        let orgs = [O(name: "busy", activity: 40), O(name: "quiet", activity: 2), O(name: "mid", activity: 7)]
        XCTAssertEqual(order(orgs, by: .byActivity, ascending: false), ["busy", "mid", "quiet"],
                       "busiest org first")
    }

    func testByActivityBreaksTiesByCaseInsensitiveName() {
        // Equal activity must fall back to a stable, case-insensitive name order in the ascending build.
        let orgs = [O(name: "delta", activity: 5), O(name: "Bravo", activity: 5), O(name: "charlie", activity: 5)]
        XCTAssertEqual(order(orgs, by: .byActivity, ascending: true), ["Bravo", "charlie", "delta"])
    }

    // MARK: edges

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(order([], by: .manual, ascending: true), [])
        XCTAssertEqual(order([], by: .byName, ascending: false), [])
        XCTAssertEqual(order([], by: .byActivity, ascending: true), [])
    }

    func testDefaultModeIsManual() {
        XCTAssertEqual(OrgOrderingMode.default, .manual)
    }
}
