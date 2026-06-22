import XCTest
@testable import Domain

/// Contract tests for the pure `GitHubDelta.apply` diff. It keys by `id`, calls a row "changed"
/// when it isn't `==` to its previous value, and reports which ids are new/changed and which are
/// gone — the primitive the data layer uses to skip a no-op refresh (and, later, to re-lay only the
/// rows that moved). Exercised on both `GitHubRepo` and `GitHubOrg` to prove the generic works
/// across the GitHub value types.
final class GitHubDeltaTests: XCTestCase {
    private func repo(_ id: String, open: Int = 0) -> GitHubRepo {
        GitHubRepo(id: id, name: id, owner: "acme", openIssues: open, openPullRequests: 0)
    }

    // MARK: - merged is the resolved set (incoming order + values)

    func testMergedEqualsIncomingInIncomingOrder() {
        let existing = [repo("a"), repo("b")]
        let incoming = [repo("b"), repo("c"), repo("a")]   // reordered + one new, one gone
        let out = GitHubDelta.apply(incoming: incoming, to: existing)
        XCTAssertEqual(out.merged, incoming)
    }

    // MARK: - changedIDs = new ∪ value-changed

    func testNewRowsAreReportedAsChanged() {
        let out = GitHubDelta.apply(incoming: [repo("a"), repo("b")], to: [repo("a")])
        XCTAssertEqual(out.changedIDs, ["b"])
        XCTAssertTrue(out.removedIDs.isEmpty)
    }

    func testValueChangedRowsAreReportedAsChanged() {
        let out = GitHubDelta.apply(incoming: [repo("a", open: 5)], to: [repo("a", open: 1)])
        XCTAssertEqual(out.changedIDs, ["a"])
        XCTAssertTrue(out.removedIDs.isEmpty)
    }

    func testUnchangedRowsAreNotReported() {
        let same = [repo("a", open: 3), repo("b")]
        let out = GitHubDelta.apply(incoming: same, to: same)
        XCTAssertTrue(out.changedIDs.isEmpty)
        XCTAssertTrue(out.removedIDs.isEmpty)
        XCTAssertTrue(out.isUnchanged)
        XCTAssertEqual(out.merged, same)
    }

    func testReorderingAloneIsNotAChange() {
        let out = GitHubDelta.apply(incoming: [repo("b"), repo("a")], to: [repo("a"), repo("b")])
        XCTAssertTrue(out.isUnchanged, "same rows in a different order carry no per-row change")
    }

    // MARK: - removedIDs = existing ids no longer present

    func testGoneRowsAreReportedAsRemoved() {
        let out = GitHubDelta.apply(incoming: [repo("a")], to: [repo("a"), repo("b")])
        XCTAssertEqual(out.removedIDs, ["b"])
        XCTAssertTrue(out.changedIDs.isEmpty)
        XCTAssertFalse(out.isUnchanged)
    }

    // MARK: - empties

    func testEmptyIncomingRemovesEverything() {
        let out = GitHubDelta.apply(incoming: [], to: [repo("a"), repo("b")])
        XCTAssertTrue(out.merged.isEmpty)
        XCTAssertEqual(out.removedIDs, ["a", "b"])
        XCTAssertTrue(out.changedIDs.isEmpty)
    }

    func testEmptyExistingMakesEverythingNew() {
        let out = GitHubDelta.apply(incoming: [repo("a"), repo("b")], to: [])
        XCTAssertEqual(out.changedIDs, ["a", "b"])
        XCTAssertTrue(out.removedIDs.isEmpty)
    }

    func testBothEmptyIsUnchanged() {
        let out = GitHubDelta.apply(incoming: [GitHubRepo](), to: [GitHubRepo]())
        XCTAssertTrue(out.isUnchanged)
        XCTAssertTrue(out.merged.isEmpty)
    }

    // MARK: - works for another GitHub type (the generic is type-agnostic)

    func testWorksForOrgs() {
        let before = GitHubOrg(id: "1", login: "acme", repositories: [repo("a")])
        let after = GitHubOrg(id: "1", login: "acme", repositories: [repo("a", open: 2)])
        let fresh = GitHubOrg(id: "2", login: "globex")
        let out = GitHubDelta.apply(incoming: [after, fresh], to: [before])
        XCTAssertEqual(out.changedIDs, ["1", "2"])   // org 1 changed (its repo counts), org 2 is new
        XCTAssertTrue(out.removedIDs.isEmpty)
        XCTAssertEqual(out.merged, [after, fresh])
    }
}
