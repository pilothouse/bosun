import XCTest
import Domain
@testable import Application

/// Contract tests for the request/remove-reviewers use case, driven through its `GitHubAPI` port.
/// The seam lets us run against a fake here instead of live github.com: we assert the use case
/// forwards the logins and rejects an empty set before the network is ever touched.
final class ManageReviewersUseCaseTests: XCTestCase {

    // MARK: Fake (in-test implementation of the GitHubAPI port)

    /// Records each request/remove call and returns a canned reviewer list. The other methods are
    /// never exercised by this use case, so they throw to make an accidental call loud.
    private actor FakeGitHubAPI: GitHubAPI {
        struct Call: Equatable { let kind: String; let owner, repo: String; let number: Int; let logins: [String] }
        private(set) var calls: [Call] = []
        private let reply: [GitHubReviewer]
        init(reply: [GitHubReviewer]) { self.reply = reply }

        func requestReviewers(owner: String, repo: String, number: Int, logins: [String]) -> [GitHubReviewer] {
            calls.append(Call(kind: "request", owner: owner, repo: repo, number: number, logins: logins))
            return reply
        }
        func removeRequestedReviewers(owner: String, repo: String, number: Int, logins: [String]) -> [GitHubReviewer] {
            calls.append(Call(kind: "remove", owner: owner, repo: repo, number: number, logins: logins))
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
        func mergePullRequest(owner: String, repo: String, number: Int,
                              merge: PRMergeRequest) throws -> PRMergeResult { throw Unused() }
        func editItem(owner: String, repo: String, number: Int, edit: GitHubItemEdit) throws -> GitHubItem { throw Unused() }
        func repositoryLabels(owner: String, repo: String) throws -> [GitHubLabel] { throw Unused() }
        func assignableUsers(owner: String, repo: String) throws -> [GitHubActor] { throw Unused() }
        func searchIssues(owner: String, repo: String, query: String) throws -> [GitHubItem] { throw Unused() }
        func closePullRequest(owner: String, repo: String, number: Int) throws -> GitHubItem { throw Unused() }
        func closeIssue(owner: String, repo: String, number: Int, reason: IssueCloseReason) throws -> GitHubItem { throw Unused() }
        func deleteBranch(owner: String, repo: String, branch: String) throws { throw Unused() }
    }

    private let pending = [GitHubReviewer(login: "kim", state: .pending)]

    // MARK: Tests

    func testRequestForwardsLoginsAndReturnsThePendingSet() async throws {
        let api = FakeGitHubAPI(reply: pending)
        let useCase = ManageReviewersUseCase(api: api)

        let result = try await useCase.request(owner: "acme-corp", repo: "api-gateway", number: 482,
                                               logins: ["kim", "raj"])

        XCTAssertEqual(result, pending)
        let calls = await api.calls
        XCTAssertEqual(calls, [.init(kind: "request", owner: "acme-corp", repo: "api-gateway",
                                     number: 482, logins: ["kim", "raj"])])
    }

    func testRemoveForwardsLoginsAndReturnsThePendingSet() async throws {
        let api = FakeGitHubAPI(reply: [])
        let useCase = ManageReviewersUseCase(api: api)

        let result = try await useCase.remove(owner: "acme-corp", repo: "api-gateway", number: 482,
                                              logins: ["kim"])

        XCTAssertEqual(result, [])
        let calls = await api.calls
        XCTAssertEqual(calls, [.init(kind: "remove", owner: "acme-corp", repo: "api-gateway",
                                     number: 482, logins: ["kim"])])
    }

    func testEmptyLoginsThrowsAndNeverCallsTheAPI() async {
        let api = FakeGitHubAPI(reply: pending)
        let useCase = ManageReviewersUseCase(api: api)

        for action in ["request", "remove"] {
            do {
                if action == "request" {
                    _ = try await useCase.request(owner: "a", repo: "b", number: 1, logins: [])
                } else {
                    _ = try await useCase.remove(owner: "a", repo: "b", number: 1, logins: [])
                }
                XCTFail("expected ManageReviewersError.empty for an empty logins set (\(action))")
            } catch {
                XCTAssertEqual(error as? ManageReviewersError, .empty)
            }
        }
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty, "an empty request/remove must not touch the API")
    }
}
