import XCTest
import Domain
@testable import Application

/// Contract tests for the edit-an-item use case, driven through its `GitHubAPI` port. The seam lets
/// us run against a fake here instead of live github.com: we assert the use case forwards only the
/// fields being changed (with the title trimmed), rejects a blank edited title, and refuses a no-op
/// edit — all before the network is ever touched.
final class EditItemUseCaseTests: XCTestCase {

    // MARK: Fake (in-test implementation of the GitHubAPI port)

    /// Records each `editItem` call and returns a canned item. The other methods are never exercised
    /// by this use case, so they throw to make an accidental call loud.
    private actor FakeGitHubAPI: GitHubAPI {
        struct Call: Equatable {
            let owner, repo: String
            let number: Int
            let edit: GitHubItemEdit
        }
        private(set) var calls: [Call] = []
        private let reply: GitHubItem
        init(reply: GitHubItem) { self.reply = reply }

        func editItem(owner: String, repo: String, number: Int, edit: GitHubItemEdit) -> GitHubItem {
            calls.append(Call(owner: owner, repo: repo, number: number, edit: edit))
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
        func repositoryLabels(owner: String, repo: String) throws -> [GitHubLabel] { throw Unused() }
        func assignableUsers(owner: String, repo: String) throws -> [GitHubActor] { throw Unused() }
    }

    private func item(title: String = "Updated") -> GitHubItem {
        GitHubItem(id: "acme-corp/api-gateway#482", number: 482, kind: .issue, title: title,
                   state: .open, author: GitHubActor(login: "octocat"),
                   createdAt: Date(timeIntervalSince1970: 0), body: "body",
                   repositoryNameWithOwner: "acme-corp/api-gateway")
    }

    // MARK: Tests

    func testForwardsTrimmedTitleAndReturnsStoredItem() async throws {
        let stored = item(title: "New title")
        let api = FakeGitHubAPI(reply: stored)
        let edit = EditItemUseCase(api: api)

        let result = try await edit(owner: "acme-corp", repo: "api-gateway", number: 482,
                                    edit: GitHubItemEdit(title: "  New title  \n", body: "new body"))

        XCTAssertEqual(result, stored, "the use case returns the item exactly as the API stored it")
        let calls = await api.calls
        XCTAssertEqual(calls, [.init(owner: "acme-corp", repo: "api-gateway", number: 482,
                                     edit: GitHubItemEdit(title: "New title", body: "new body"))],
                       "the title must be trimmed before it reaches the API; body passes through untouched")
    }

    func testForwardsLabelsAndAssigneesAsGiven() async throws {
        let api = FakeGitHubAPI(reply: item())
        let edit = EditItemUseCase(api: api)

        _ = try await edit(owner: "acme-corp", repo: "api-gateway", number: 482,
                           edit: GitHubItemEdit(labels: ["bug", "p1"], assignees: ["ann", "bob"]))

        let calls = await api.calls
        XCTAssertEqual(calls.first?.edit.labels, ["bug", "p1"], "the full label set passes through")
        XCTAssertEqual(calls.first?.edit.assignees, ["ann", "bob"], "the full assignee set passes through")
        XCTAssertNil(calls.first?.edit.title, "an unchanged field stays nil so it isn't sent")
    }

    func testEmptyBodyIsAValidEdit() async throws {
        let api = FakeGitHubAPI(reply: item())
        let edit = EditItemUseCase(api: api)

        _ = try await edit(owner: "acme-corp", repo: "api-gateway", number: 482,
                           edit: GitHubItemEdit(body: ""))

        let calls = await api.calls
        XCTAssertEqual(calls.first?.edit.body, "", "clearing the body is allowed — it's sent as an empty string")
    }

    func testBlankTitleThrowsAndNeverCallsTheAPI() async {
        let api = FakeGitHubAPI(reply: item())
        let edit = EditItemUseCase(api: api)

        do {
            _ = try await edit(owner: "acme-corp", repo: "api-gateway", number: 482,
                               edit: GitHubItemEdit(title: "   \n  "))
            XCTFail("expected EditItemError.emptyTitle for a whitespace-only title")
        } catch {
            XCTAssertEqual(error as? EditItemError, .emptyTitle)
        }
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty, "a blank title must not be saved")
    }

    func testEmptyEditThrowsNoChangesAndNeverCallsTheAPI() async {
        let api = FakeGitHubAPI(reply: item())
        let edit = EditItemUseCase(api: api)

        do {
            _ = try await edit(owner: "acme-corp", repo: "api-gateway", number: 482, edit: GitHubItemEdit())
            XCTFail("expected EditItemError.noChanges for an edit that changes nothing")
        } catch {
            XCTAssertEqual(error as? EditItemError, .noChanges)
        }
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty, "a no-op edit must not issue a write")
    }
}
