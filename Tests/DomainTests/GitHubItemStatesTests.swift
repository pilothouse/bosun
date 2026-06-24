import XCTest
@testable import Domain

/// Contract tests for the pure multi-status filter rules. They describe what `GitHubItemStates`
/// promises outward — which states a fetch ends up requesting given the user's selection, when a
/// fetch is bounded, and how a state maps to its GraphQL token — not how it works inside. Don't
/// edit a contract test to make an implementation pass; if the contract is wrong, flag it.
final class GitHubItemStatesTests: XCTestCase {

    // MARK: requested

    func testRequestedPassesAPRSelectionThrough() {
        XCTAssertEqual(GitHubItemStates.requested(for: .pullRequest, selected: [.open, .merged]),
                       [.open, .merged],
                       "PRs keep every selected state, including merged")
    }

    func testRequestedDropsMergedForIssues() {
        XCTAssertEqual(GitHubItemStates.requested(for: .issue, selected: [.open, .closed, .merged]),
                       [.open, .closed],
                       "issues have no merged state, so it's dropped from the request")
    }

    func testRequestedFallsBackToOpenWhenSelectionIsEmpty() {
        XCTAssertEqual(GitHubItemStates.requested(for: .pullRequest, selected: []), [.open],
                       "an empty selection must never ask the API for nothing")
        XCTAssertEqual(GitHubItemStates.requested(for: .issue, selected: []), [.open])
    }

    func testRequestedFallsBackToOpenWhenDroppingMergedEmptiesAnIssueSelection() {
        // The UI never offers merged for issues, but the rule guards the degenerate set anyway.
        XCTAssertEqual(GitHubItemStates.requested(for: .issue, selected: [.merged]), [.open])
    }

    // MARK: bounded

    func testOpenOnlyIsUnbounded() {
        XCTAssertFalse(GitHubItemStates.bounded([.open]),
                       "the open-only fast path fetches the full working set")
    }

    func testAnyBroaderSelectionIsBounded() {
        XCTAssertTrue(GitHubItemStates.bounded([.open, .closed]))
        XCTAssertTrue(GitHubItemStates.bounded([.closed]))
        XCTAssertTrue(GitHubItemStates.bounded([.merged]))
        XCTAssertTrue(GitHubItemStates.bounded([.open, .closed, .merged]))
    }

    // MARK: graphQLToken

    func testGraphQLTokensMatchGitHubsEnumNames() {
        XCTAssertEqual(GitHubItemStates.graphQLToken(.open), "OPEN")
        XCTAssertEqual(GitHubItemStates.graphQLToken(.closed), "CLOSED")
        XCTAssertEqual(GitHubItemStates.graphQLToken(.merged), "MERGED")
    }
}
