import XCTest
import Domain
@testable import Application

/// Contract tests for the close-a-PR use case, driven through its `GitHubAPI` port. They pin the
/// ordering rule (close first, then the branch) and the partial-failure fold: once the PR is closed, a
/// branch-delete failure returns a `.failed` outcome rather than throwing — the close still counts.
final class ClosePullRequestUseCaseTests: XCTestCase {

    // MARK: Fake (in-test implementation of the GitHubAPI port)

    private actor FakeGitHubAPI: GitHubAPI {
        struct CloseCall: Equatable { let owner, repo: String; let number: Int }
        struct DeleteCall: Equatable { let owner, repo, branch: String }
        private(set) var closeCalls: [CloseCall] = []
        private(set) var deleteCalls: [DeleteCall] = []
        private let closed: GitHubItem
        private let closeError: Error?
        private let deleteError: Error?

        init(closed: GitHubItem, closeError: Error? = nil, deleteError: Error? = nil) {
            self.closed = closed
            self.closeError = closeError
            self.deleteError = deleteError
        }

        func closePullRequest(owner: String, repo: String, number: Int) throws -> GitHubItem {
            closeCalls.append(CloseCall(owner: owner, repo: repo, number: number))
            if let closeError { throw closeError }
            return closed
        }

        func deleteBranch(owner: String, repo: String, branch: String) throws {
            deleteCalls.append(DeleteCall(owner: owner, repo: repo, branch: branch))
            if let deleteError { throw deleteError }
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
        func mergePullRequest(owner: String, repo: String, number: Int,
                              merge: PRMergeRequest) throws -> PRMergeResult { throw Unused() }
        func editItem(owner: String, repo: String, number: Int, edit: GitHubItemEdit) throws -> GitHubItem { throw Unused() }
        func requestReviewers(owner: String, repo: String, number: Int, logins: [String]) throws -> [GitHubReviewer] { throw Unused() }
        func removeRequestedReviewers(owner: String, repo: String, number: Int, logins: [String]) throws -> [GitHubReviewer] { throw Unused() }
        func repositoryLabels(owner: String, repo: String) throws -> [GitHubLabel] { throw Unused() }
        func assignableUsers(owner: String, repo: String) throws -> [GitHubActor] { throw Unused() }
    }

    private let pr = GitHubItem(id: "acme/api#7", number: 7, kind: .pullRequest, title: "Ship it",
                                state: .closed, author: GitHubActor(login: "octocat"),
                                createdAt: Date(timeIntervalSince1970: 0),
                                body: "", repositoryNameWithOwner: "acme/api")

    // MARK: Tests

    func testCloseWithoutBranchDeletionLeavesTheBranchAlone() async throws {
        let api = FakeGitHubAPI(closed: pr)
        let close = ClosePullRequestUseCase(api: api)

        let result = try await close(owner: "acme", repo: "api", number: 7,
                                     branch: "feature/foo", deleteBranch: false)

        XCTAssertEqual(result.item, pr, "the use case returns the closed PR as the API reported it")
        XCTAssertEqual(result.branchDeletion, .notRequested)
        let closes = await api.closeCalls
        let deletes = await api.deleteCalls
        XCTAssertEqual(closes, [.init(owner: "acme", repo: "api", number: 7)])
        XCTAssertEqual(deletes, [], "deleteBranch=false must not touch the branch")
    }

    func testCloseThenDeletesTheHeadBranch() async throws {
        let api = FakeGitHubAPI(closed: pr)
        let close = ClosePullRequestUseCase(api: api)

        let result = try await close(owner: "acme", repo: "api", number: 7,
                                     branch: "feature/foo", deleteBranch: true)

        XCTAssertEqual(result.branchDeletion, .deleted)
        let deletes = await api.deleteCalls
        XCTAssertEqual(deletes, [.init(owner: "acme", repo: "api", branch: "feature/foo")])
    }

    func testBranchDeleteFailureFoldsIntoResultWithoutThrowing() async throws {
        let api = FakeGitHubAPI(closed: pr, deleteError: GitHubAPIError.notFound)
        let close = ClosePullRequestUseCase(api: api)

        let result = try await close(owner: "acme", repo: "api", number: 7,
                                     branch: "feature/foo", deleteBranch: true)

        // The PR still closed; only the branch delete failed, folded in as a reason (not thrown).
        XCTAssertEqual(result.item, pr)
        guard case .failed = result.branchDeletion else {
            return XCTFail("a post-close branch-delete failure should fold into .failed, not throw")
        }
        let closes = await api.closeCalls
        XCTAssertEqual(closes.count, 1, "the close happened before the failing delete")
    }

    func testCloseFailurePropagatesAndSkipsTheBranchDelete() async throws {
        let api = FakeGitHubAPI(closed: pr, closeError: GitHubAPIError.http(status: 403))
        let close = ClosePullRequestUseCase(api: api)

        do {
            _ = try await close(owner: "acme", repo: "api", number: 7,
                                branch: "feature/foo", deleteBranch: true)
            XCTFail("a close failure must throw")
        } catch {
            // expected
        }
        let deletes = await api.deleteCalls
        XCTAssertEqual(deletes, [], "a failed close must not attempt a branch delete")
    }

    func testEmptyBranchIsTreatedAsNoDeletion() async throws {
        let api = FakeGitHubAPI(closed: pr)
        let close = ClosePullRequestUseCase(api: api)

        let result = try await close(owner: "acme", repo: "api", number: 7,
                                     branch: "", deleteBranch: true)

        XCTAssertEqual(result.branchDeletion, .notRequested)
        let deletes = await api.deleteCalls
        XCTAssertEqual(deletes, [], "an empty branch name means there's nothing to delete")
    }
}
