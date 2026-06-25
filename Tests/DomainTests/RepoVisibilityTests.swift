import XCTest
@testable import Domain

/// Contract tests for the pure repo-visibility rule. They describe what `RepoVisibility` promises
/// outward — which repos the panel shows for a given `skipEmpty` choice — not how it works inside.
/// Like `RepoOrdering`, the rule operates on an `open` projection so Domain needn't know the App's
/// presentation `Repo` type; a tiny local fixture supplies it. Don't edit a contract test to make
/// an implementation pass; if the contract is wrong, flag it.
final class RepoVisibilityTests: XCTestCase {

    private struct R { let name: String; let open: Int }

    private func visible(_ repos: [R], skipEmpty: Bool) -> [String] {
        RepoVisibility.visible(repos, skipEmpty: skipEmpty, open: \.open).map(\.name)
    }

    func testSkipEmptyOffReturnsEveryRepoInOrder() {
        let repos = [R(name: "a", open: 0), R(name: "b", open: 3), R(name: "c", open: 0)]
        XCTAssertEqual(visible(repos, skipEmpty: false), ["a", "b", "c"],
                       "off means show all, untouched — including the empty ones, in their incoming order")
    }

    func testSkipEmptyOnDropsZeroOpenKeepsTheRest() {
        let repos = [R(name: "a", open: 0), R(name: "b", open: 3), R(name: "c", open: 0), R(name: "d", open: 1)]
        XCTAssertEqual(visible(repos, skipEmpty: true), ["b", "d"],
                       "on drops repos whose open issue+PR count is zero, preserving the order of the rest")
    }

    func testSkipEmptyOnWithAllEmptyReturnsEmpty() {
        let repos = [R(name: "a", open: 0), R(name: "b", open: 0)]
        XCTAssertEqual(visible(repos, skipEmpty: true), [])
    }

    func testSkipEmptyOnWithNoneEmptyReturnsAll() {
        let repos = [R(name: "a", open: 1), R(name: "b", open: 9)]
        XCTAssertEqual(visible(repos, skipEmpty: true), ["a", "b"])
    }

    func testEmptyInputReturnsEmptyRegardlessOfFlag() {
        XCTAssertEqual(visible([], skipEmpty: false), [])
        XCTAssertEqual(visible([], skipEmpty: true), [])
    }
}
