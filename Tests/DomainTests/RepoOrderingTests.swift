import XCTest
@testable import Domain

/// Contract tests for the pure repo-ordering rule. They describe what `RepoOrdering` promises
/// outward — the order repos take for a given mode — not how it works inside. The rule operates on
/// `(name, open)` projections so Domain needn't know the App's presentation `Repo` type; here a
/// tiny local fixture supplies those. Don't edit a contract test to make an implementation pass;
/// if the contract is wrong, flag it.
final class RepoOrderingTests: XCTestCase {

    private struct R { let name: String; let open: Int }

    private func order(_ repos: [R], by mode: RepoOrderingMode) -> [String] {
        RepoOrdering.order(repos, by: mode, name: \.name, open: \.open).map(\.name)
    }

    // MARK: byName

    func testByNameSortsCaseInsensitivelyAscending() {
        let repos = [R(name: "beta", open: 1), R(name: "Alpha", open: 9), R(name: "gamma", open: 0)]
        XCTAssertEqual(order(repos, by: .byName), ["Alpha", "beta", "gamma"],
                       "name order ignores case and ignores the open count")
    }

    // MARK: byOpenCount

    func testByOpenCountSortsDescending() {
        let repos = [R(name: "low", open: 2), R(name: "high", open: 40), R(name: "mid", open: 7)]
        XCTAssertEqual(order(repos, by: .byOpenCount), ["high", "mid", "low"],
                       "busiest repo first")
    }

    func testByOpenCountBreaksTiesByCaseInsensitiveName() {
        // Equal counts must fall back to a stable, case-insensitive name order.
        let repos = [R(name: "delta", open: 5), R(name: "Bravo", open: 5), R(name: "charlie", open: 5)]
        XCTAssertEqual(order(repos, by: .byOpenCount), ["Bravo", "charlie", "delta"])
    }

    // MARK: edges

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(order([], by: .byName), [])
        XCTAssertEqual(order([], by: .byOpenCount), [])
    }

    func testDefaultModeIsByName() {
        XCTAssertEqual(RepoOrderingMode.default, .byName)
    }
}
