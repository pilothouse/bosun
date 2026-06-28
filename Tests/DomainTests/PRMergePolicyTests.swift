import XCTest
@testable import Domain

/// Contract tests for the pure PR-merge rule. They describe what `PRMergePolicy` promises outward —
/// which PR states allow a merge and the reason it surfaces when they don't — not how it checks it.
/// Mirrors `FolderPolicyTests`. Don't edit a contract test to make an implementation pass.
final class PRMergePolicyTests: XCTestCase {

    func testAllowsAnOpenMergeableCleanPR() {
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .open,
                                       mergeable: true, mergeStateStatus: "CLEAN"),
            .allowed)
    }

    func testBlocksIssuesAndNonOpenPRs() {
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .issue, state: .open,
                                       mergeable: true, mergeStateStatus: "CLEAN"),
            .blocked(reason: "Only an open pull request can be merged"))
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .merged,
                                       mergeable: true, mergeStateStatus: "CLEAN"),
            .blocked(reason: "Only an open pull request can be merged"))
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .closed,
                                       mergeable: true, mergeStateStatus: "CLEAN"),
            .blocked(reason: "Only an open pull request can be merged"))
    }

    func testBlocksADraftEvenWhenOtherwiseMergeable() {
        // A draft can still report mergeable == true, so the status must be checked first.
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .open,
                                       mergeable: true, mergeStateStatus: "DRAFT"),
            .blocked(reason: "This pull request is a draft"))
    }

    func testBlocksWhenBranchProtectionBlocksTheMerge() {
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .open,
                                       mergeable: true, mergeStateStatus: "BLOCKED"),
            .blocked(reason: "Merging is blocked (required reviews or checks)"))
    }

    func testBlocksOnConflicts() {
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .open,
                                       mergeable: false, mergeStateStatus: "DIRTY"),
            .blocked(reason: "Conflicts must be resolved before merging"))
    }

    func testBlocksWhileMergeabilityIsStillUnknown() {
        // GitHub computes mergeability asynchronously; nil reads as "not yet known".
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .open,
                                       mergeable: nil, mergeStateStatus: "UNKNOWN"),
            .blocked(reason: "Checking if this can be merged…"))
        XCTAssertEqual(
            PRMergePolicy.availability(kind: .pullRequest, state: .open,
                                       mergeable: nil, mergeStateStatus: nil),
            .blocked(reason: "Checking if this can be merged…"))
    }
}
