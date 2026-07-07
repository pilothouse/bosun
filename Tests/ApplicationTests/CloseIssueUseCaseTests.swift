import XCTest
import Domain
@testable import Application

/// Contract tests for the close-an-issue use case, driven through its `GitHubAPI` port. They pin the
/// duplicate orchestration: closing as a duplicate posts the `Duplicate of #N` marker comment *before*
/// closing (GitHub only links the duplicate when that comment exists), while every other reason — and a
/// duplicate close with no parent — closes without any comment.
final class CloseIssueUseCaseTests: XCTestCase {

    // MARK: Fake (in-test implementation of the GitHubAPI port)

    private actor FakeGitHubAPI: GitHubAPI {
        /// The port calls in the order they happened, so a test can assert comment-before-close.
        enum Event: Equatable { case comment(String); case close(IssueCloseReason) }
        private(set) var events: [Event] = []
        private let closed: GitHubItem

        init(closed: GitHubItem) { self.closed = closed }

        func addComment(owner: String, repo: String, number: Int, body: String) -> GitHubComment {
            events.append(.comment(body))
            return GitHubComment(author: GitHubActor(login: "octocat"),
                                 createdAt: Date(timeIntervalSince1970: 0), body: body)
        }

        func closeIssue(owner: String, repo: String, number: Int,
                        reason: IssueCloseReason) -> GitHubItem {
            events.append(.close(reason))
            return closed
        }

        private struct Unused: Error {}
        func currentUser() throws -> GitHubUser { throw Unused() }
        func organizations() throws -> [GitHubOrg] { throw Unused() }
        func viewerRepositories() throws -> [GitHubRepo] { throw Unused() }
        func items(owner: String, repo: String, kind: GitHubItemKind,
                   states: Set<GitHubItemState>) throws -> GitHubItemList { throw Unused() }
        func batchItems(owner: String, repos: [String], kind: GitHubItemKind,
                        states: Set<GitHubItemState>) throws -> [GitHubRepoItems] { throw Unused() }
        func itemDetail(owner: String, repo: String, number: Int) throws -> GitHubItem { throw Unused() }
        func issueDependencies(owner: String, repo: String, number: Int) throws -> [Int] { throw Unused() }
        func mergePullRequest(owner: String, repo: String, number: Int,
                              merge: PRMergeRequest) throws -> PRMergeResult { throw Unused() }
        func editItem(owner: String, repo: String, number: Int, edit: GitHubItemEdit) throws -> GitHubItem { throw Unused() }
        func requestReviewers(owner: String, repo: String, number: Int, logins: [String]) throws -> [GitHubReviewer] { throw Unused() }
        func removeRequestedReviewers(owner: String, repo: String, number: Int, logins: [String]) throws -> [GitHubReviewer] { throw Unused() }
        func repositoryLabels(owner: String, repo: String) throws -> [GitHubLabel] { throw Unused() }
        func assignableUsers(owner: String, repo: String) throws -> [GitHubActor] { throw Unused() }
        func searchIssues(owner: String, repo: String, query: String) throws -> [GitHubItem] { throw Unused() }
        func closePullRequest(owner: String, repo: String, number: Int) throws -> GitHubItem { throw Unused() }
        func deleteBranch(owner: String, repo: String, branch: String) throws { throw Unused() }
    }

    private let issue = GitHubItem(id: "acme/api#7", number: 7, kind: .issue, title: "Bug",
                                   state: .closed, author: GitHubActor(login: "octocat"),
                                   createdAt: Date(timeIntervalSince1970: 0),
                                   body: "", repositoryNameWithOwner: "acme/api")

    // MARK: Tests

    func testDuplicateWithParentPostsMarkerCommentThenCloses() async throws {
        let api = FakeGitHubAPI(closed: issue)
        let closeIssue = CloseIssueUseCase(api: api)
        _ = try await closeIssue(owner: "acme", repo: "api", number: 7, reason: .duplicate, duplicateOf: 42)
        let events = await api.events
        XCTAssertEqual(events, [.comment("Duplicate of #42"), .close(.duplicate)])
    }

    func testCompletedReasonPostsNoComment() async throws {
        let api = FakeGitHubAPI(closed: issue)
        let closeIssue = CloseIssueUseCase(api: api)
        _ = try await closeIssue(owner: "acme", repo: "api", number: 7, reason: .completed, duplicateOf: 42)
        let events = await api.events
        XCTAssertEqual(events, [.close(.completed)])   // duplicateOf ignored for non-duplicate reasons
    }

    func testDuplicateWithoutParentPostsNoComment() async throws {
        let api = FakeGitHubAPI(closed: issue)
        let closeIssue = CloseIssueUseCase(api: api)
        _ = try await closeIssue(owner: "acme", repo: "api", number: 7, reason: .duplicate)
        let events = await api.events
        XCTAssertEqual(events, [.close(.duplicate)])
    }

    func testReturnsTheClosedIssueFromTheAPI() async throws {
        let api = FakeGitHubAPI(closed: issue)
        let closeIssue = CloseIssueUseCase(api: api)
        let result = try await closeIssue(owner: "acme", repo: "api", number: 7, reason: .notPlanned)
        XCTAssertEqual(result, issue)
    }
}
