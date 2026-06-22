import XCTest
@testable import Application
@testable import Domain
@testable import Infrastructure

/// Contract tests for the on-disk GitHub cache adapter: it round-trips the viewer's data (proving
/// the new `Codable` conformances), scopes everything to one login (a different account drops the
/// previous data), clears on sign-out, and treats a missing or corrupt file as an empty cache
/// rather than throwing — caching must never crash the app.
final class JSONFileGitHubCacheStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-cache-tests-\(UUID().uuidString)", isDirectory: true)
        url = dir.appendingPathComponent("github-cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> JSONFileGitHubCacheStore { JSONFileGitHubCacheStore(url: url) }

    private func repo(_ id: String, open: Int = 0) -> GitHubRepo {
        GitHubRepo(id: id, name: id, owner: "maya", openIssues: open, openPullRequests: 0)
    }

    private func item(_ number: Int, title: String = "t") -> GitHubItem {
        GitHubItem(id: "node-\(number)", number: number, kind: .pullRequest, title: title,
                   state: .open, author: GitHubActor(login: "maya"), createdAt: Date(timeIntervalSince1970: 0),
                   body: "", repositoryNameWithOwner: "maya/app")
    }

    func testEmptyWhenNothingSaved() async {
        let cache = store()
        let login = await cache.cachedLogin()
        let orgs = await cache.loadOrgs()
        let items = await cache.loadItems(repoKey: "maya/app", kind: .pullRequest)
        XCTAssertNil(login)
        XCTAssertTrue(orgs.isEmpty)
        XCTAssertTrue(items.isEmpty)
    }

    func testRoundTripsOrgsReposAndItemsAcrossInstances() async {
        let orgs = [GitHubOrg(id: "1", login: "acme", name: "Acme", repositories: [repo("r1", open: 3)])]
        let repos = [repo("p1", open: 1)]
        let items = [item(10), item(11, title: "second")]

        let writer = store()
        await writer.saveOrgs(orgs, viewerRepos: repos, login: "maya")
        await writer.saveItems(items, repoKey: "maya/app", kind: .pullRequest)

        // A fresh actor instance reads from disk, proving persistence + Codable round-trip.
        let reader = store()
        let readLogin = await reader.cachedLogin()
        let readOrgs = await reader.loadOrgs()
        let readRepos = await reader.loadViewerRepos()
        let readItems = await reader.loadItems(repoKey: "maya/app", kind: .pullRequest)
        XCTAssertEqual(readLogin, "maya")
        XCTAssertEqual(readOrgs, orgs)
        XCTAssertEqual(readRepos, repos)
        XCTAssertEqual(readItems, items)
    }

    func testItemsAreKeyedByRepoAndKind() async {
        let cache = store()
        await cache.saveOrgs([], viewerRepos: [], login: "maya")
        await cache.saveItems([item(1)], repoKey: "maya/app", kind: .pullRequest)
        await cache.saveItems([item(2), item(3)], repoKey: "maya/app", kind: .issue)

        let prs = await cache.loadItems(repoKey: "maya/app", kind: .pullRequest)
        let issues = await cache.loadItems(repoKey: "maya/app", kind: .issue)
        let otherRepo = await cache.loadItems(repoKey: "maya/other", kind: .pullRequest)
        XCTAssertEqual(prs.map(\.number), [1])
        XCTAssertEqual(issues.map(\.number), [2, 3])
        XCTAssertTrue(otherRepo.isEmpty)
    }

    func testSavingADifferentLoginDropsThePreviousAccountsData() async {
        let cache = store()
        await cache.saveOrgs([GitHubOrg(id: "1", login: "acme")], viewerRepos: [repo("p1")], login: "maya")
        await cache.saveItems([item(1)], repoKey: "maya/app", kind: .pullRequest)

        // Account switch: same store, new login.
        await cache.saveOrgs([GitHubOrg(id: "9", login: "globex")], viewerRepos: [], login: "alex")

        let login = await cache.cachedLogin()
        let orgs = await cache.loadOrgs()
        let staleItems = await cache.loadItems(repoKey: "maya/app", kind: .pullRequest)
        XCTAssertEqual(login, "alex")
        XCTAssertEqual(orgs.map(\.id), ["9"])
        XCTAssertTrue(staleItems.isEmpty, "the previous account's items must not survive a login change")
    }

    func testClearEmptiesEverythingAndRemovesTheFile() async {
        let cache = store()
        await cache.saveOrgs([GitHubOrg(id: "1", login: "acme")], viewerRepos: [repo("p1")], login: "maya")
        await cache.saveItems([item(1)], repoKey: "maya/app", kind: .pullRequest)

        await cache.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let login = await cache.cachedLogin()
        let orgs = await cache.loadOrgs()
        XCTAssertNil(login)
        XCTAssertTrue(orgs.isEmpty)
    }

    func testCorruptFileReadsAsEmpty() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: url)

        let cache = store()
        let login = await cache.cachedLogin()
        let orgs = await cache.loadOrgs()
        XCTAssertNil(login)
        XCTAssertTrue(orgs.isEmpty, "a corrupt cache is a miss, not a crash")
    }
}
