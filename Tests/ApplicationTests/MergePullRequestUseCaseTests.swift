import XCTest
import Domain
@testable import Application

/// Contract tests for the merge-a-PR use case, driven through its `GitHubAPI` port. The seam lets
/// us run against a fake here instead of live github.com: we assert the use case forwards the
/// chosen method and the edited commit text, normalizing a blank title/message to `nil` so GitHub
/// falls back to its own default commit text.
final class MergePullRequestUseCaseTests: XCTestCase {

    // MARK: Fake (in-test implementation of the GitHubAPI port)

    /// Records each `mergePullRequest` call and returns a canned result. The read/comment methods
    /// are never exercised by this use case, so they throw to make an accidental call loud.
    private actor FakeGitHubAPI: GitHubAPI {
        struct Call: Equatable {
            let owner, repo: String
            let number: Int
            let merge: PRMergeRequest
        }
        private(set) var calls: [Call] = []
        private let reply: PRMergeResult
        init(reply: PRMergeResult) { self.reply = reply }

        func mergePullRequest(owner: String, repo: String, number: Int,
                              merge: PRMergeRequest) -> PRMergeResult {
            calls.append(Call(owner: owner, repo: repo, number: number, merge: merge))
            return reply
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
        func addComment(owner: String, repo: String, number: Int, body: String) throws -> GitHubComment { throw Unused() }
        func editItem(owner: String, repo: String, number: Int, edit: GitHubItemEdit) throws -> GitHubItem { throw Unused() }
        func requestReviewers(owner: String, repo: String, number: Int, logins: [String]) throws -> [GitHubReviewer] { throw Unused() }
        func removeRequestedReviewers(owner: String, repo: String, number: Int, logins: [String]) throws -> [GitHubReviewer] { throw Unused() }
        func repositoryLabels(owner: String, repo: String) throws -> [GitHubLabel] { throw Unused() }
        func assignableUsers(owner: String, repo: String) throws -> [GitHubActor] { throw Unused() }
        func searchIssues(owner: String, repo: String, query: String) throws -> [GitHubItem] { throw Unused() }
        func closePullRequest(owner: String, repo: String, number: Int) throws -> GitHubItem { throw Unused() }
        func closeIssue(owner: String, repo: String, number: Int, reason: IssueCloseReason) throws -> GitHubItem { throw Unused() }
        func deleteBranch(owner: String, repo: String, branch: String) throws { throw Unused() }
    }

    private let merged = PRMergeResult(merged: true, sha: "abc123", message: "Pull Request successfully merged")

    // MARK: Tests

    func testForwardsMethodAndTrimmedCommitTextAndReturnsResult() async throws {
        let api = FakeGitHubAPI(reply: merged)
        let merge = MergePullRequestUseCase(api: api)

        let result = try await merge(owner: "acme-corp", repo: "api-gateway", number: 482,
                                     merge: PRMergeRequest(method: .squash, commitTitle: "  Ship it  ",
                                                           commitMessage: "  release notes  \n"))

        XCTAssertEqual(result, merged, "the use case returns the merge result exactly as the API reported it")
        let calls = await api.calls
        XCTAssertEqual(calls, [.init(owner: "acme-corp", repo: "api-gateway", number: 482,
                                     merge: PRMergeRequest(method: .squash, commitTitle: "Ship it",
                                                           commitMessage: "release notes"))],
                       "the method passes through and the commit text is trimmed before it reaches the API")
    }

    func testBlankCommitTitleAndMessageBecomeNil() async throws {
        let api = FakeGitHubAPI(reply: merged)
        let merge = MergePullRequestUseCase(api: api)

        _ = try await merge(owner: "acme-corp", repo: "api-gateway", number: 482,
                            merge: PRMergeRequest(method: .merge, commitTitle: "   ", commitMessage: ""))

        let calls = await api.calls
        XCTAssertEqual(calls.first?.merge.commitTitle, nil, "a blank title is sent as nil so GitHub uses its default")
        XCTAssertEqual(calls.first?.merge.commitMessage, nil, "a blank message is sent as nil so GitHub uses its default")
    }

    func testNilCommitTextPassesThroughAsNil() async throws {
        let api = FakeGitHubAPI(reply: merged)
        let merge = MergePullRequestUseCase(api: api)

        _ = try await merge(owner: "acme-corp", repo: "api-gateway", number: 7,
                            merge: PRMergeRequest(method: .rebase, commitTitle: nil, commitMessage: nil))

        let calls = await api.calls
        XCTAssertEqual(calls, [.init(owner: "acme-corp", repo: "api-gateway", number: 7,
                                     merge: PRMergeRequest(method: .rebase, commitTitle: nil, commitMessage: nil))])
    }
}
