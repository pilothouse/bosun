import XCTest
@testable import Domain

/// Contract tests for the pure tree-flattening rule behind the panel's "By parent" / "By blocked-by"
/// grouping. They pin what `GitHubItemTree.rows` promises: an ordered, indented row list where a
/// relationship is honored only if the related item is in view, descendants of a collapsed node are
/// hidden (the node itself stays, marked as having children), and a cyclic relationship never loops.
/// Don't edit a contract test to make an implementation pass; if the contract is wrong, flag it.
final class GitHubItemTreeTests: XCTestCase {

    private func row(_ id: Int, _ depth: Int, _ hasChildren: Bool) -> GitHubItemTree.Row<Int> {
        GitHubItemTree.Row(id: id, depth: depth, hasChildren: hasChildren)
    }

    func testFlatListHasNoParentsAllAtDepthZero() {
        let rows = GitHubItemTree.rows(order: [1, 2, 3], parentOf: [:])
        XCTAssertEqual(rows, [row(1, 0, false), row(2, 0, false), row(3, 0, false)])
    }

    func testSingleLevelNestsChildrenUnderTheirParent() {
        let rows = GitHubItemTree.rows(order: [1, 2, 3], parentOf: [2: 1, 3: 1])
        XCTAssertEqual(rows, [row(1, 0, true), row(2, 1, false), row(3, 1, false)])
    }

    func testMultiLevelNestingIncreasesDepth() {
        let rows = GitHubItemTree.rows(order: [1, 2, 3], parentOf: [2: 1, 3: 2])
        XCTAssertEqual(rows, [row(1, 0, true), row(2, 1, true), row(3, 2, false)])
    }

    func testItemWhoseParentIsNotInViewBecomesARoot() {
        // Parent #1 is filtered out of `order`; its child must still appear (as a root), not vanish.
        let rows = GitHubItemTree.rows(order: [2, 3], parentOf: [2: 1])
        XCTAssertEqual(rows, [row(2, 0, false), row(3, 0, false)])
    }

    func testSiblingAndRootOrderFollowsTheInputOrder() {
        // Roots and siblings keep `order`'s sequence; #1 nests under #3, #2 stays a root after it.
        let rows = GitHubItemTree.rows(order: [3, 1, 2], parentOf: [1: 3])
        XCTAssertEqual(rows, [row(3, 0, true), row(1, 1, false), row(2, 0, false)])
    }

    func testCollapsedParentHidesDescendantsButStaysMarked() {
        let rows = GitHubItemTree.rows(order: [1, 2, 3], parentOf: [2: 1, 3: 1], collapsed: [1])
        XCTAssertEqual(rows, [row(1, 0, true)])
    }

    func testCollapsingAMidLevelNodeHidesOnlyItsSubtree() {
        let rows = GitHubItemTree.rows(order: [1, 2, 3], parentOf: [2: 1, 3: 2], collapsed: [2])
        XCTAssertEqual(rows, [row(1, 0, true), row(2, 1, true)])
    }

    func testCycleTerminatesAndEveryItemAppearsOnce() {
        // #1 blocks #2 and #2 blocks #1 — a 2-cycle. The render must not loop, and neither item
        // may be dropped: one is promoted to a root, the other nests under it, each shown once.
        let rows = GitHubItemTree.rows(order: [1, 2], parentOf: [1: 2, 2: 1])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)), [1, 2])
    }

    func testSelfParentIsTreatedAsARoot() {
        let rows = GitHubItemTree.rows(order: [1], parentOf: [1: 1])
        XCTAssertEqual(rows, [row(1, 0, false)])
    }

    func testMultipleRootsEachKeepTheirOwnSubtree() {
        let rows = GitHubItemTree.rows(order: [1, 2, 3, 4], parentOf: [2: 1, 4: 3])
        XCTAssertEqual(rows, [row(1, 0, true), row(2, 1, false), row(3, 0, true), row(4, 1, false)])
    }
}
