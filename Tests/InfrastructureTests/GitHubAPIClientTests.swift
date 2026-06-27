import XCTest
import Application
import Domain
@testable import Infrastructure

/// Exercises `GitHubAPIClient` end-to-end through its `GitHubAPI` port: a stubbed `URLSession`
/// feeds canned GitHub payloads so the real request-building, JSON decoding, REST pagination,
/// GraphQL/REST mapping, and status→`GitHubAPIError` translation all run — no live network.
/// These describe what the adapter promises (decoded `Domain` entities, typed errors), not how
/// it builds a request.
final class GitHubAPIClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: REST decoding

    func testCurrentUserDecodesRESTUser() async throws {
        respond { (self.ok($0), try fixture("user")) }
        let user = try await makeClient().currentUser()
        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.name, "The Octocat")
        XCTAssertEqual(user.avatarURL?.host, "avatars.githubusercontent.com")
    }

    // MARK: GraphQL decoding

    func testOrganizationsDecodesNestedReposAndCounts() async throws {
        respond { (self.ok($0), try fixture("organizations")) }
        let orgs = try await makeClient().organizations()

        XCTAssertEqual(orgs.count, 1)
        let acme = try XCTUnwrap(orgs.first)
        XCTAssertEqual(acme.login, "acme-corp")
        XCTAssertEqual(acme.avatarURL?.host, "avatars.githubusercontent.com")
        XCTAssertEqual(acme.repositories.map(\.name), ["api-gateway", "web-dashboard"])
        let gateway = try XCTUnwrap(acme.repositories.first)
        XCTAssertEqual(gateway.openIssues, 8)
        XCTAssertEqual(gateway.openPullRequests, 3)
        XCTAssertEqual(gateway.nameWithOwner, "acme-corp/api-gateway")
    }

    func testOrganizationsDropNullNodesForInaccessibleReposAndOrgs() async throws {
        // GitHub returns `null` for a connection node the token can't read (a restricted/archived/
        // transferred repo or org) instead of omitting it. A non-optional element used to abort the
        // whole decode, so one unreadable repo silently froze the org panel at its cache (#81).
        respond { (self.ok($0), try fixture("organizations-null-nodes")) }
        let orgs = try await makeClient().organizations()

        XCTAssertEqual(orgs.map(\.login), ["acme-corp", "beta-inc"], "the null org node is dropped")
        let acme = try XCTUnwrap(orgs.first)
        XCTAssertEqual(acme.repositories.map(\.name), ["api-gateway", "web-dashboard"],
                       "the null repo node is dropped; the readable repos around it still decode")
    }

    func testOrganizationsPaginatesAcrossCursorPages() async throws {
        // The org page size is kept small to stay under GitHub's GraphQL query-cost limit, so real
        // accounts span several pages — the cursor loop must stitch them together (#81).
        let calls = CallCounter()
        StubURLProtocol.handler = { request in
            let n = calls.bump()
            return (self.ok(request), try fixture(n == 1 ? "organizations-page1" : "organizations-page2"))
        }
        let orgs = try await makeClient().organizations()

        XCTAssertEqual(calls.count, 2, "follows the cursor for a second page while hasNextPage is true")
        XCTAssertEqual(orgs.map(\.login), ["acme-corp", "beta-inc"], "both pages aggregate, in order")
    }

    func testViewerRepositoriesDecodesOwnedReposAndCounts() async throws {
        respond { (self.ok($0), try fixture("viewer-repositories")) }
        let repos = try await makeClient().viewerRepositories()

        XCTAssertEqual(repos.map(\.name), ["dotfiles", "side-project"])
        let dotfiles = try XCTUnwrap(repos.first)
        XCTAssertEqual(dotfiles.owner, "octocat")
        XCTAssertEqual(dotfiles.openIssues, 4)
        XCTAssertEqual(dotfiles.openPullRequests, 1)
        XCTAssertEqual(dotfiles.nameWithOwner, "octocat/dotfiles")
    }

    func testViewerRepositoriesDropsNullNodes() async throws {
        respond { (self.ok($0), try fixture("viewer-repositories-null-node")) }
        let repos = try await makeClient().viewerRepositories()

        XCTAssertEqual(repos.map(\.name), ["dotfiles", "side-project"],
                       "a null (inaccessible) repo node is dropped rather than failing the decode (#81)")
    }

    func testIssuesListMapsFieldsAndParsesTasksFromBody() async throws {
        respond { (self.ok($0), try fixture("issues")) }
        let result = try await makeClient().items(owner: "acme-corp", repo: "api-gateway",
                                                  kind: .issue, states: [.open])
        let items = result.items

        XCTAssertFalse(result.reachedHistoryCap, "the open-only fast path is unbounded")
        XCTAssertEqual(items.count, 2)
        let first = items[0]
        XCTAssertEqual(first.kind, .issue)
        XCTAssertEqual(first.number, 482)
        XCTAssertEqual(first.state, .open)
        XCTAssertEqual(first.labels, ["bug", "p1"])
        XCTAssertEqual(first.author.login, "maya")
        XCTAssertEqual(first.repositoryNameWithOwner, "acme-corp/api-gateway")
        // tasks are derived from the markdown body by the Domain rule.
        XCTAssertEqual(first.tasks, [
            GitHubTask(title: "reproduce", isDone: true),
            GitHubTask(title: "write fix", isDone: false),
            GitHubTask(title: "add test", isDone: false),
        ])
        // A null author maps to the GitHub "ghost" sentinel rather than failing to decode.
        XCTAssertEqual(items[1].author.login, "ghost")
    }

    func testIssuesListCarriesSubIssueParentNumber() async throws {
        respond { (self.ok($0), try fixture("issues")) }
        let items = try await makeClient().items(owner: "acme-corp", repo: "api-gateway",
                                                 kind: .issue, states: [.open]).items
        XCTAssertEqual(items[0].parentNumber, 440, "the sub-issue parent rides the list fetch")
        XCTAssertNil(items[1].parentNumber, "an issue with no parent stays nil")
    }

    func testListQueryOptsIntoTheSubIssuesFeature() async throws {
        let captured = RequestBox()
        StubURLProtocol.handler = { request in
            captured.value = request
            return (self.ok(request), try fixture("issues"))
        }
        _ = try await makeClient().items(owner: "acme-corp", repo: "api-gateway",
                                         kind: .issue, states: [.open])
        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.value(forHTTPHeaderField: "GraphQL-Features"), "sub_issues",
                       "GraphQL list requests must opt into sub_issues so `parent` resolves")
    }

    // MARK: Batched org items (aggregate org view)

    func testBatchItemsAliasesManyReposIntoOneRequest() async throws {
        let calls = CallCounter()
        StubURLProtocol.handler = { request in
            calls.bump()
            return (self.ok(request), try fixture("org-items-batch"))
        }
        let result = try await makeClient().batchItems(
            owner: "acme-corp", repos: ["api-gateway", "web-dashboard", "billing"],
            kind: .issue, states: [.open])

        XCTAssertEqual(calls.count, 1, "three repos resolve in a single aliased GraphQL request")
        XCTAssertEqual(result.map(\.repositoryNameWithOwner),
                       ["acme-corp/api-gateway", "acme-corp/web-dashboard", "acme-corp/billing"],
                       "one entry per repo, in the order asked, owner-qualified")
        // Each alias's items are grouped under its own repo and carry that repo's name.
        XCTAssertEqual(result[0].items.map(\.number), [482])
        XCTAssertEqual(result[0].items.first?.repositoryNameWithOwner, "acme-corp/api-gateway")
        XCTAssertEqual(result[1].items.map(\.number), [91])
        XCTAssertEqual(result[2].items.map(\.number), [7])
        XCTAssertEqual(result[2].items.first?.kind, .issue)
    }

    func testBatchItemsPagesOnlyTheRepoThatOverflowed() async throws {
        let calls = CallCounter()
        StubURLProtocol.handler = { request in
            let n = calls.bump()
            // First call is the batch (r0 reports more pages); the follow-up is the full single-repo fetch.
            return (self.ok(request), try fixture(n == 1 ? "org-items-batch-overflow" : "issues"))
        }
        let result = try await makeClient().batchItems(
            owner: "acme-corp", repos: ["api-gateway"], kind: .issue, states: [.open])

        XCTAssertEqual(calls.count, 2, "an overflowing repo triggers exactly one full-fetch follow-up")
        // The complete set replaces the partial first page (the `issues` fixture carries 2 items).
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].items.count, 2)
        XCTAssertEqual(result[0].items.first?.repositoryNameWithOwner, "acme-corp/api-gateway")
    }

    func testBatchItemsOmitsAnInaccessibleRepo() async throws {
        respond { (self.ok($0), try fixture("org-items-batch-null")) }
        let result = try await makeClient().batchItems(
            owner: "acme-corp", repos: ["api-gateway", "secret-repo"], kind: .issue, states: [.open])

        XCTAssertEqual(result.map(\.repositoryNameWithOwner), ["acme-corp/api-gateway"],
                       "a null (inaccessible) alias is dropped so its cache stays untouched")
    }

    func testBatchItemsOptsIntoTheSubIssuesFeature() async throws {
        let captured = RequestBox()
        StubURLProtocol.handler = { request in
            captured.value = request
            return (self.ok(request), try fixture("org-items-batch"))
        }
        _ = try await makeClient().batchItems(
            owner: "acme-corp", repos: ["api-gateway"], kind: .issue, states: [.open])
        XCTAssertEqual(captured.value?.value(forHTTPHeaderField: "GraphQL-Features"), "sub_issues",
                       "the batched issues query must opt into sub_issues like the per-repo list query")
    }

    func testBatchItemsWithNoReposMakesNoRequest() async throws {
        let calls = CallCounter()
        StubURLProtocol.handler = { request in calls.bump(); return (self.ok(request), Data("{}".utf8)) }
        let result = try await makeClient().batchItems(owner: "acme-corp", repos: [], kind: .issue, states: [.open])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(calls.count, 0, "no repos → no network")
    }

    // MARK: Issue dependencies (blocked-by)

    func testIssueDependenciesReturnsSameRepoBlockerNumbers() async throws {
        let captured = RequestBox()
        StubURLProtocol.handler = { request in
            captured.value = request
            return (self.ok(request), try fixture("dependencies-blocked-by"))
        }
        let blockers = try await makeClient().issueDependencies(
            owner: "acme-corp", repo: "api-gateway", number: 482)

        XCTAssertEqual(blockers, [440], "cross-repo blockers are dropped; only same-repo numbers remain")
        XCTAssertEqual(captured.value?.url?.path,
                       "/repos/acme-corp/api-gateway/issues/482/dependencies/blocked_by")
    }

    // MARK: Detail = GraphQL core + REST comments

    func testItemDetailComposesChecksAndComments() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/graphql") { return (self.ok(request), try fixture("item-detail")) }
            return (self.ok(request), try fixture("comments"))   // single page, no Link header
        }
        let item = try await makeClient().itemDetail(owner: "acme-corp", repo: "api-gateway", number: 482)

        XCTAssertEqual(item.kind, .pullRequest)
        XCTAssertEqual(item.branch, "fix/rate-limiter")
        XCTAssertEqual(item.additions, 124)
        XCTAssertEqual(item.deletions, 18)
        XCTAssertEqual(item.tasks, [
            GitHubTask(title: "code", isDone: true),
            GitHubTask(title: "docs", isDone: false),
        ])

        XCTAssertEqual(item.checks.map(\.name), ["CI / build", "CI / e2e", "license/cla"])
        XCTAssertEqual(item.checks[0].state, .success)
        XCTAssertEqual(item.checks[0].durationSeconds, 102)     // 08:17:42 − 08:16:00
        XCTAssertEqual(item.checks[1].state, .inProgress)
        XCTAssertNil(item.checks[1].durationSeconds)
        XCTAssertEqual(item.checks[2].state, .success)          // legacy StatusContext

        XCTAssertEqual(item.comments.count, 1)
        XCTAssertEqual(item.comments.first?.author.login, "raj")
        XCTAssertEqual(item.comments.first?.authorAssociation, "MEMBER")
    }

    func testItemDetailMapsChangedFiles() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/graphql") { return (self.ok(request), try fixture("item-detail")) }
            return (self.ok(request), try fixture("comments"))
        }
        let item = try await makeClient().itemDetail(owner: "acme-corp", repo: "api-gateway", number: 482)

        let files = try XCTUnwrap(item.files)
        XCTAssertEqual(files.map(\.path), [
            "Sources/RateLimiter.swift", "Sources/Burst.swift",
            "Sources/Legacy.swift", "Tests/RateLimiterTests.swift",
        ])
        XCTAssertEqual(files.map(\.change), [.modified, .added, .removed, .renamed])  // DELETED → removed
        XCTAssertEqual(files[0].additions, 80)
        XCTAssertEqual(files[0].deletions, 10)
    }

    func testCommentsPaginationFollowsLinkHeader() async throws {
        let nextURL = "https://api.github.com/repos/acme-corp/api-gateway/issues/482/comments?per_page=100&page=2"
        StubURLProtocol.handler = { request in
            let url = request.url!
            if url.path.contains("/graphql") { return (self.ok(request), try fixture("item-detail")) }
            if url.query?.contains("page=2") == true {
                return (self.ok(request), try fixture("comments-page2"))   // last page, no Link
            }
            return (self.ok(request, headers: ["Link": "<\(nextURL)>; rel=\"next\""]), try fixture("comments"))
        }
        let item = try await makeClient().itemDetail(owner: "acme-corp", repo: "api-gateway", number: 482)

        // Both pages aggregated into one comment list, in order.
        XCTAssertEqual(item.comments.map(\.author.login), ["raj", "maya"])
    }

    // MARK: Write (the one mutation)

    func testAddCommentPostsBodyAndDecodesCreatedComment() async throws {
        let captured = RequestBox()
        StubURLProtocol.handler = { request in
            captured.value = request
            return (self.status(request, 201), try fixture("comment-created"))   // GitHub returns 201 Created
        }
        let body = "Thanks — fixing the retry path now."
        let comment = try await makeClient().addComment(
            owner: "acme-corp", repo: "api-gateway", number: 482, body: body)

        // Decodes the single created-comment object (not a list) into a Domain entity.
        XCTAssertEqual(comment.author.login, "octocat")
        XCTAssertEqual(comment.body, body)
        XCTAssertEqual(comment.authorAssociation, "OWNER")

        // POSTs `{ "body": ... }` to the issue-comments endpoint.
        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/repos/acme-corp/api-gateway/issues/482/comments")
        let sent = try XCTUnwrap(bodyData(request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: String])
        XCTAssertEqual(json, ["body": body])
    }

    // MARK: Error mapping

    func testNoStoredTokenIsUnauthorizedWithoutHittingNetwork() async throws {
        await assertThrows(.unauthorized) { try await makeClient(token: nil).currentUser() }
    }

    func test401MapsToUnauthorized() async throws {
        respond { (self.status($0, 401), Data("{}".utf8)) }
        await assertThrows(.unauthorized) { try await makeClient().currentUser() }
    }

    func test404MapsToNotFound() async throws {
        respond { (self.status($0, 404), Data("{}".utf8)) }
        await assertThrows(.notFound) { try await makeClient().currentUser() }
    }

    func testExhausted403MapsToRateLimited() async throws {
        respond {
            (self.status($0, 403, headers: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "1700000000",
            ]), Data("{}".utf8))
        }
        await assertThrows(.rateLimited(resetAt: Date(timeIntervalSince1970: 1_700_000_000))) {
            try await makeClient().currentUser()
        }
    }

    func testForbiddenWithBudgetRemainingMapsToHTTP403() async throws {
        respond { (self.status($0, 403), Data("{}".utf8)) }   // no rate-limit headers
        await assertThrows(.http(status: 403)) { try await makeClient().currentUser() }
    }

    // MARK: - Helpers

    private func makeClient(token: String? = "gho_test") -> GitHubAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return GitHubAPIClient(tokenStore: FakeTokenStore(token: token),
                               session: URLSession(configuration: config))
    }

    /// Install a handler that ignores the request and returns one fixed `(response, body)`.
    private func respond(_ make: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        StubURLProtocol.handler = make
    }

    private func ok(_ request: URLRequest, headers: [String: String] = [:]) -> HTTPURLResponse {
        status(request, 200, headers: headers)
    }

    private func status(_ request: URLRequest, _ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    /// The request body URLSession hands a `URLProtocol`. It often moves `httpBody` into a stream,
    /// so read whichever is set — lets us assert what `addComment` actually serialized.
    private func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func assertThrows(_ expected: GitHubAPIError,
                              _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected) but got \(error)", file: file, line: line)
        }
    }
}

/// Captures the request the stub saw, so a test can assert method/URL/body after the call returns.
private final class RequestBox: @unchecked Sendable {
    var value: URLRequest?
}

/// Counts how many requests the stub answered — lets a test assert the batched fetch collapses
/// many repos into one round-trip. The stub handler runs on URLSession's loading thread, so the
/// count is guarded by a lock.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func bump() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A canned `GitHubTokenStore` — returns a fixed token (or nil to simulate signed-out).
private actor FakeTokenStore: GitHubTokenStore {
    private let token: String?
    init(token: String?) { self.token = token }
    func load() -> String? { token }
    func save(_ token: String) {}
    func delete() {}
}

/// Load a JSON fixture bundled with the test target.
private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
