import XCTest
import Domain
@testable import Application

/// Contract tests for the post-a-comment use case, driven through its `GitHubAPI` port. The seam
/// lets us run against a fake here instead of live github.com: we assert the use case forwards the
/// *trimmed* body and rejects a blank one before the network is ever touched.
final class AddCommentUseCaseTests: XCTestCase {

    // MARK: Fake (in-test implementation of the GitHubAPI port)

    /// Records each `addComment` call and returns a canned comment. The read methods are never
    /// exercised by this use case, so they throw to make an accidental call loud.
    private actor FakeGitHubAPI: GitHubAPI {
        struct Call: Equatable { let owner, repo: String; let number: Int; let body: String }
        private(set) var calls: [Call] = []
        private let reply: GitHubComment
        init(reply: GitHubComment) { self.reply = reply }

        func addComment(owner: String, repo: String, number: Int, body: String) -> GitHubComment {
            calls.append(Call(owner: owner, repo: repo, number: number, body: body))
            return reply
        }

        private struct Unused: Error {}
        func currentUser() throws -> GitHubUser { throw Unused() }
        func organizations() throws -> [GitHubOrg] { throw Unused() }
        func viewerRepositories() throws -> [GitHubRepo] { throw Unused() }
        func items(owner: String, repo: String, kind: GitHubItemKind,
                   states: Set<GitHubItemState>) throws -> GitHubItemList { throw Unused() }
        func itemDetail(owner: String, repo: String, number: Int) throws -> GitHubItem { throw Unused() }
    }

    private func comment(body: String, by login: String = "octocat") -> GitHubComment {
        GitHubComment(author: GitHubActor(login: login),
                      createdAt: Date(timeIntervalSince1970: 0),
                      body: body, authorAssociation: "OWNER")
    }

    // MARK: Tests

    func testPostsTrimmedBodyAndReturnsStoredComment() async throws {
        let stored = comment(body: "looks good")
        let api = FakeGitHubAPI(reply: stored)
        let addComment = AddCommentUseCase(api: api)

        let result = try await addComment(owner: "acme-corp", repo: "api-gateway", number: 482,
                                          body: "  looks good  \n")

        XCTAssertEqual(result, stored, "the use case returns the comment exactly as the API stored it")
        let calls = await api.calls
        XCTAssertEqual(calls, [.init(owner: "acme-corp", repo: "api-gateway", number: 482, body: "looks good")],
                       "the body must be trimmed before it reaches the API")
    }

    func testBlankBodyThrowsAndNeverCallsTheAPI() async {
        let api = FakeGitHubAPI(reply: comment(body: ""))
        let addComment = AddCommentUseCase(api: api)

        do {
            _ = try await addComment(owner: "acme-corp", repo: "api-gateway", number: 482, body: "   \n  ")
            XCTFail("expected AddCommentError.empty for a whitespace-only body")
        } catch {
            XCTAssertEqual(error as? AddCommentError, .empty)
        }
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty, "a blank comment must not be posted")
    }
}
