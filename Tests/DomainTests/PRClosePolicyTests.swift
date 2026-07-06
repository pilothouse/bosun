import XCTest
@testable import Domain

/// Contract tests for the pure PR-close rules. They describe what `PRClosePolicy` promises outward —
/// which items may be closed, and when the head-branch deletion is offered — not how it decides.
/// Mirrors `PRMergePolicyTests`. Don't edit a contract test to make an implementation pass.
final class PRClosePolicyTests: XCTestCase {

    // MARK: canClose

    func testAllowsClosingAnOpenPR() {
        XCTAssertTrue(PRClosePolicy.canClose(kind: .pullRequest, state: .open))
    }

    func testBlocksClosingIssuesAndNonOpenPRs() {
        XCTAssertFalse(PRClosePolicy.canClose(kind: .issue, state: .open),
                       "the close-PR control isn't for issues")
        XCTAssertFalse(PRClosePolicy.canClose(kind: .pullRequest, state: .closed),
                       "an already-closed PR has nothing to close")
        XCTAssertFalse(PRClosePolicy.canClose(kind: .pullRequest, state: .merged),
                       "a merged PR has nothing to close")
    }

    // MARK: branchDeletable

    func testOffersDeletionForASameRepoFeatureBranch() {
        XCTAssertTrue(PRClosePolicy.branchDeletable(
            branch: "feature/foo", baseRefName: "main", isCrossRepository: false))
    }

    func testHidesDeletionForAForkPR() {
        // A fork's head branch lives in another repo — it can't be deleted from the base repo.
        XCTAssertFalse(PRClosePolicy.branchDeletable(
            branch: "feature/foo", baseRefName: "main", isCrossRepository: true))
    }

    func testHidesDeletionWhileCrossRepositoryIsStillUnknown() {
        // Detail-hydrated; nil reads as "not yet known", so the option stays hidden to avoid offering
        // to delete a fork branch before the detail confirms it's same-repo.
        XCTAssertFalse(PRClosePolicy.branchDeletable(
            branch: "feature/foo", baseRefName: "main", isCrossRepository: nil))
    }

    func testHidesDeletionForTheBaseBranch() {
        XCTAssertFalse(PRClosePolicy.branchDeletable(
            branch: "main", baseRefName: "main", isCrossRepository: false))
    }

    func testHidesDeletionWhenThereIsNoBranch() {
        XCTAssertFalse(PRClosePolicy.branchDeletable(
            branch: nil, baseRefName: "main", isCrossRepository: false))
        XCTAssertFalse(PRClosePolicy.branchDeletable(
            branch: "", baseRefName: "main", isCrossRepository: false))
    }
}
