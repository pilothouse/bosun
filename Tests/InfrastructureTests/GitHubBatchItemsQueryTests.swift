import XCTest
import Domain
@testable import Infrastructure

/// Drives the pure builder behind the aggregate org view's batched fetch:
/// `GitHubGraphQLQueries.batchItems(repoCount:kind:)` aliases N repos into one GraphQL document
/// so many repos' open issues/PRs return in a single round-trip. These describe the document's
/// shape — one `r{i}` alias per repo, per-repo `$o{i}/$n{i}` variables, a shared `$states`, and
/// the same node fields the per-repo `issues`/`pullRequests` queries select (so the existing
/// decoder maps each alias node unchanged).
final class GitHubBatchItemsQueryTests: XCTestCase {

    func testIssuesQueryAliasesEachRepoWithPerRepoVariables() {
        let query = GitHubGraphQLQueries.batchItems(repoCount: 2, kind: .issue)

        // One typed states variable, plus an owner/name variable pair per repo.
        XCTAssertTrue(query.contains("$states: [IssueState!]"), "issues filter is typed IssueState")
        XCTAssertTrue(query.contains("$o0: String!"))
        XCTAssertTrue(query.contains("$n0: String!"))
        XCTAssertTrue(query.contains("$o1: String!"))
        XCTAssertTrue(query.contains("$n1: String!"))

        // One aliased repository selection per repo, wired to that repo's variables.
        XCTAssertTrue(query.contains("r0: repository(owner: $o0, name: $n0)"))
        XCTAssertTrue(query.contains("r1: repository(owner: $o1, name: $n1)"))

        // Each alias selects the issues connection with paging info and the sub-issue parent.
        XCTAssertTrue(query.contains("issues(first: 50"))
        XCTAssertTrue(query.contains("states: $states"))
        XCTAssertTrue(query.contains("pageInfo { hasNextPage endCursor }"))
        XCTAssertTrue(query.contains("parent { number }"), "issues carry the sub-issue parent")
        XCTAssertFalse(query.contains("pullRequests("), "an issues batch must not query PRs")
    }

    func testPullRequestsQueryUsesPRStateTypeAndPRFields() {
        let query = GitHubGraphQLQueries.batchItems(repoCount: 1, kind: .pullRequest)

        XCTAssertTrue(query.contains("$states: [PullRequestState!]"), "PR filter is typed PullRequestState")
        XCTAssertTrue(query.contains("r0: repository(owner: $o0, name: $n0)"))
        XCTAssertTrue(query.contains("pullRequests(first: 50"))
        // PR-only lead fields the presentation layer needs.
        XCTAssertTrue(query.contains("isDraft"))
        XCTAssertTrue(query.contains("headRefName"))
        XCTAssertFalse(query.contains("\n    issues("), "a PR batch must not query issues")
    }

    func testRepoCountControlsAliasCount() {
        let query = GitHubGraphQLQueries.batchItems(repoCount: 3, kind: .issue)
        XCTAssertTrue(query.contains("r2: repository(owner: $o2, name: $n2)"))
        XCTAssertFalse(query.contains("r3:"), "exactly repoCount aliases, no more")
    }
}
