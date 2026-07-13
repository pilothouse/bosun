import Application
import Domain
import Foundation

// MARK: - Offline UI-test seed data and in-memory adapters
//
// Everything here is inert unless `CompositionRoot.appMode == .uiTest` (see `AppMode`). It lives in
// the App layer — the only layer allowed to import every module — alongside the existing
// `StaticTokenStore` test seam, and stays `internal`/`private` so no module's public contract widens.
//
// Why it exists: launching the real binary reads the OAuth token from the Keychain, and a rebuilt
// binary's invalidated ACL pops a blocking password dialog that freezes any scripted UI action.
// `BOSUN_UI_TEST=1` swaps the Keychain token store for an in-memory one (so `KeychainTokenStore` is
// never touched) and feeds these fixtures through the real ports, so the whole UI renders and is
// interactive fully offline. This is the single, documented replacement for the per-feature
// `BOSUN_UI_DEMO`/`BOSUN_*` seams that used to be reinvented per verification.

/// Deterministic seed data, built once from constants (no wall-clock, no network — avatar URLs are
/// nil so the avatar chips render from initials without a remote image fetch). The `FakeGitHubAPI`
/// and `InMemoryGitHubCacheStore` are both seeded from this, so the hydrate-then-delta launch path
/// paints from cache and the fake's "live" fetch diffs to unchanged.
enum UITestFixtures {
    static let login = "maya"
    static let viewer = GitHubUser(login: login, name: "Maya Ono", avatarURL: nil)

    /// A fixed base instant so fixtures never depend on the clock; each item is offset back from it.
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)  // ~2023-11-14
    private static func hoursAgo(_ hours: Int) -> Date { base.addingTimeInterval(-Double(hours) * 3600) }

    // MARK: Repos & orgs

    static let webRepo = GitHubRepo(id: "R_web", name: "web", owner: "acme",
                                    openIssues: 3, openPullRequests: 2, stargazerCount: 128)
    static let apiRepo = GitHubRepo(id: "R_api", name: "api", owner: "acme",
                                    openIssues: 1, openPullRequests: 1, stargazerCount: 64, isPrivate: true)
    static let infraRepo = GitHubRepo(id: "R_infra", name: "infra", owner: "octo-labs",
                                      openIssues: 2, openPullRequests: 0, stargazerCount: 9, isPrivate: true)
    static let dotfilesRepo = GitHubRepo(id: "R_dot", name: "dotfiles", owner: login,
                                         openIssues: 1, openPullRequests: 0, stargazerCount: 3)

    static let orgs: [GitHubOrg] = [
        GitHubOrg(id: "O_acme", login: "acme", name: "Acme Corp", avatarURL: nil,
                  repositories: [webRepo, apiRepo]),
        GitHubOrg(id: "O_octo", login: "octo-labs", name: "Octo Labs", avatarURL: nil,
                  repositories: [infraRepo]),
    ]

    /// The viewer's own repositories — surfaced as the synthetic personal group pinned above the orgs.
    static let personalRepos: [GitHubRepo] = [dotfilesRepo]

    // MARK: Actors

    static let maya = GitHubActor(login: "maya")
    static let bob = GitHubActor(login: "bob")
    static let bot = GitHubActor(login: "claude[bot]")

    // MARK: Items (both kinds), keyed by "owner/name"

    /// Every seeded issue and PR, flat per repo. The fake filters by kind/state; the cache is seeded
    /// from the same map so a selected repo hydrates instantly.
    static let items: [String: [GitHubItem]] = [
        "acme/web": [
            GitHubItem(id: "I_101", number: 101, kind: .issue, title: "Fix flaky login test",
                       state: .open, author: maya, createdAt: hoursAgo(3),
                       body: "The login test fails ~1 in 5 runs on CI.\n\n- [ ] reproduce locally\n- [ ] add a retry\n",
                       repositoryNameWithOwner: "acme/web", labels: ["bug"], assignees: [maya],
                       labelColors: ["bug": "d73a4a"]),
            GitHubItem(id: "I_102", number: 102, kind: .issue, title: "Dark mode polish",
                       state: .open, author: bob, createdAt: hoursAgo(9),
                       body: "Tighten the dark palette contrast on the sidebar.",
                       repositoryNameWithOwner: "acme/web", labels: ["enhancement", "design"],
                       labelColors: ["enhancement": "a2eeef", "design": "fbca04"]),
            GitHubItem(id: "I_103", number: 103, kind: .issue, title: "Migrate to new auth service",
                       state: .open, author: maya, createdAt: hoursAgo(20),
                       body: "Blocked on the flaky login test landing first.",
                       repositoryNameWithOwner: "acme/web", labels: ["blocked"],
                       labelColors: ["blocked": "b60205"]),
            GitHubItem(id: "I_090", number: 90, kind: .issue, title: "Crash on startup (old)",
                       state: .closed, author: bob, createdAt: hoursAgo(240),
                       body: "Fixed in 0.9.", repositoryNameWithOwner: "acme/web"),
            GitHubItem(id: "P_201", number: 201, kind: .pullRequest, title: "Add OAuth device flow",
                       state: .open, author: maya, createdAt: hoursAgo(5),
                       body: "Implements the device-flow sign-in.\n\nCloses #101.",
                       repositoryNameWithOwner: "acme/web", labels: ["enhancement"],
                       branch: "feature/oauth", additions: 320, deletions: 12,
                       comments: [
                           GitHubComment(author: bob, createdAt: hoursAgo(4),
                                         body: "Looks good — one nit on the polling interval.",
                                         authorAssociation: "MEMBER"),
                       ],
                       checks: [
                           GitHubCheck(name: "build", state: .success, durationSeconds: 102),
                           GitHubCheck(name: "test", state: .success, durationSeconds: 240),
                       ],
                       assignees: [maya], labelColors: ["enhancement": "a2eeef"],
                       mergeable: true, mergeStateStatus: "CLEAN", baseRefName: "main",
                       reviewers: [GitHubReviewer(login: "bob", state: .pending)],
                       isCrossRepository: false),
            GitHubItem(id: "P_202", number: 202, kind: .pullRequest, title: "WIP: refactor storage",
                       state: .open, author: bot, createdAt: hoursAgo(30),
                       body: "Early draft — do not merge.", repositoryNameWithOwner: "acme/web",
                       isDraft: true, branch: "wip/storage", additions: 88, deletions: 40,
                       mergeable: nil, mergeStateStatus: "DRAFT", baseRefName: "main",
                       reviewers: [], isCrossRepository: false),
        ],
        "acme/api": [
            GitHubItem(id: "I_055", number: 55, kind: .issue, title: "Rate limiter returns 500s",
                       state: .open, author: bob, createdAt: hoursAgo(12),
                       body: "Under burst load the limiter 500s instead of 429ing.",
                       repositoryNameWithOwner: "acme/api", labels: ["bug"],
                       labelColors: ["bug": "d73a4a"]),
            GitHubItem(id: "P_077", number: 77, kind: .pullRequest, title: "Bump dependencies",
                       state: .open, author: maya, createdAt: hoursAgo(26),
                       body: "Routine dependency bump.", repositoryNameWithOwner: "acme/api",
                       branch: "chore/bump", additions: 14, deletions: 14,
                       mergeable: true, mergeStateStatus: "CLEAN", baseRefName: "main",
                       reviewers: [], isCrossRepository: false),
        ],
        "octo-labs/infra": [
            GitHubItem(id: "I_012", number: 12, kind: .issue, title: "Terraform drift on staging",
                       state: .open, author: maya, createdAt: hoursAgo(48),
                       body: "Plan shows drift on the staging bucket.",
                       repositoryNameWithOwner: "octo-labs/infra"),
            GitHubItem(id: "I_013", number: 13, kind: .issue, title: "Rotate deploy secrets",
                       state: .open, author: bob, createdAt: hoursAgo(72),
                       body: "Quarterly rotation.", repositoryNameWithOwner: "octo-labs/infra",
                       labels: ["security"], labelColors: ["security": "d93f0b"]),
        ],
        "maya/dotfiles": [
            GitHubItem(id: "I_001", number: 1, kind: .issue, title: "zsh prompt is slow",
                       state: .open, author: maya, createdAt: hoursAgo(100),
                       body: "The git status segment adds ~200ms.",
                       repositoryNameWithOwner: "maya/dotfiles"),
        ],
    ]

    /// Same-repo blocked-by dependencies (for the "By blocked-by" grouping): repoKey → issue → its
    /// blockers. Issue #103 is blocked by #101.
    static let blockedBy: [String: [Int: [Int]]] = ["acme/web": [103: [101]]]

    /// The label palette per repo, for the edit pane's label picker.
    static let labels: [String: [GitHubLabel]] = [
        "acme/web": [
            GitHubLabel(name: "bug", color: "d73a4a"),
            GitHubLabel(name: "enhancement", color: "a2eeef"),
            GitHubLabel(name: "design", color: "fbca04"),
            GitHubLabel(name: "blocked", color: "b60205"),
            GitHubLabel(name: "documentation", color: "0075ca"),
        ],
        "acme/api": [GitHubLabel(name: "bug", color: "d73a4a"), GitHubLabel(name: "chore", color: "cfd3d7")],
    ]

    /// The users assignable per repo, for the edit pane's assignee picker.
    static let assignableUsers: [String: [GitHubActor]] = [
        "acme/web": [maya, bob, bot],
        "acme/api": [maya, bob],
        "octo-labs/infra": [maya, bob],
        "maya/dotfiles": [maya],
    ]

    // MARK: Connections

    // `Connection`/`Folder` are qualified `Domain.*` throughout: the Bosun module has its own
    // presentation `Connection` (id: String) that would otherwise shadow the Domain entity here.
    static let workFolder = Domain.Folder(id: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!,
                                          name: "Work")

    static let connections: [Domain.Connection] = [
        Domain.Connection(id: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!,
                          name: "prod-web-01",
                          kind: .ssh(host: "web01.acme.internal", port: 22, user: "deploy"),
                          isFavorite: true, folderId: workFolder.id),
        Domain.Connection(id: UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!,
                          name: "staging-db",
                          kind: .ssh(host: "db.staging.acme.internal", port: 2222, user: "maya"),
                          folderId: workFolder.id),
        Domain.Connection(id: UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!,
                          name: "local project",
                          kind: .localFolder(path: NSHomeDirectory())),
    ]

    static let folders: [Domain.Folder] = [workFolder]
}

// MARK: - Fake GitHub API (stateful)

/// An in-memory, stateful stand-in for the live `GitHubAPIClient`, used only in `.uiTest` mode. Reads
/// project `UITestFixtures`; writes mutate the in-memory item store and return the updated entity, so
/// the real UI write paths (comment / merge / close / edit / reviewers) work fully offline and the
/// panel updates as it would against github.com. An `actor` because it's shared mutable state reached
/// from the `@MainActor` data controller and every write use case.
actor FakeGitHubAPI: GitHubAPI {
    private var itemsByRepo: [String: [GitHubItem]]

    init(items: [String: [GitHubItem]] = UITestFixtures.items) {
        self.itemsByRepo = items
    }

    private func key(_ owner: String, _ repo: String) -> String { "\(owner)/\(repo)" }

    /// GitHub folds merged PRs under the "closed" filter, so a `.closed` selection includes them.
    private func matches(_ item: GitHubItem, _ states: Set<GitHubItemState>) -> Bool {
        if states.contains(item.state) { return true }
        return item.state == .merged && states.contains(.closed)
    }

    // Reads ------------------------------------------------------------------

    func currentUser() async throws -> GitHubUser { UITestFixtures.viewer }
    func organizations() async throws -> [GitHubOrg] { UITestFixtures.orgs }
    func viewerRepositories() async throws -> [GitHubRepo] { UITestFixtures.personalRepos }

    func items(owner: String, repo: String, kind: GitHubItemKind,
               states: Set<GitHubItemState>) async throws -> GitHubItemList {
        let all = itemsByRepo[key(owner, repo)] ?? []
        let filtered = all.filter { $0.kind == kind && matches($0, states) }
        return GitHubItemList(items: filtered)
    }

    func searchIssues(owner: String, repo: String, query: String) async throws -> [GitHubItem] {
        let all = (itemsByRepo[key(owner, repo)] ?? []).filter { $0.kind == .issue }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
        return hits.sorted { $0.number > $1.number }
    }

    func batchItems(owner: String, repos: [String], kind: GitHubItemKind,
                    states: Set<GitHubItemState>) async throws -> [GitHubRepoItems] {
        repos.map { repo in
            let all = itemsByRepo[key(owner, repo)] ?? []
            let filtered = all.filter { $0.kind == kind && matches($0, states) }
            return GitHubRepoItems(repositoryNameWithOwner: key(owner, repo), items: filtered)
        }
    }

    func itemDetail(owner: String, repo: String, number: Int) async throws -> GitHubItem {
        guard let item = itemsByRepo[key(owner, repo)]?.first(where: { $0.number == number }) else {
            throw GitHubAPIError.notFound
        }
        return item
    }

    func issueDependencies(owner: String, repo: String, number: Int) async throws -> [Int] {
        UITestFixtures.blockedBy[key(owner, repo)]?[number] ?? []
    }

    func repositoryLabels(owner: String, repo: String) async throws -> [GitHubLabel] {
        UITestFixtures.labels[key(owner, repo)] ?? []
    }

    func assignableUsers(owner: String, repo: String) async throws -> [GitHubActor] {
        UITestFixtures.assignableUsers[key(owner, repo)] ?? []
    }

    // Writes -----------------------------------------------------------------

    /// Replace the stored item matching `number` in `repoKey` via `transform`, returning the new value.
    @discardableResult
    private func mutate(_ owner: String, _ repo: String, number: Int,
                        _ transform: (GitHubItem) -> GitHubItem) throws -> GitHubItem {
        let k = key(owner, repo)
        guard var list = itemsByRepo[k], let idx = list.firstIndex(where: { $0.number == number }) else {
            throw GitHubAPIError.notFound
        }
        let updated = transform(list[idx])
        list[idx] = updated
        itemsByRepo[k] = list
        return updated
    }

    func addComment(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment {
        let comment = GitHubComment(author: UITestFixtures.viewer.asActor,
                                    createdAt: UITestFixtures.now, body: body, authorAssociation: "OWNER")
        try mutate(owner, repo, number: number) { $0.with(comments: $0.comments + [comment]) }
        return comment
    }

    func mergePullRequest(owner: String, repo: String, number: Int,
                          merge: PRMergeRequest) async throws -> PRMergeResult {
        try mutate(owner, repo, number: number) { $0.with(state: .merged) }
        return PRMergeResult(merged: true, sha: "0fakesha0fakesha0fakesha0fakesha0fakesha",
                             message: "Pull request successfully merged")
    }

    func editItem(owner: String, repo: String, number: Int,
                  edit: GitHubItemEdit) async throws -> GitHubItem {
        try mutate(owner, repo, number: number) { item in
            let newAssignees = edit.assignees.map { logins in logins.map { GitHubActor(login: $0) } }
            return item.with(title: edit.title, body: edit.body, labels: edit.labels,
                             assignees: newAssignees)
        }
    }

    func requestReviewers(owner: String, repo: String, number: Int,
                          logins: [String]) async throws -> [GitHubReviewer] {
        let updated = try mutate(owner, repo, number: number) { item in
            var pending = (item.reviewers ?? []).filter { $0.state == .pending }
            for login in logins where !pending.contains(where: { $0.login == login }) {
                pending.append(GitHubReviewer(login: login, state: .pending))
            }
            let others = (item.reviewers ?? []).filter { $0.state != .pending }
            return item.with(reviewers: others + pending)
        }
        return (updated.reviewers ?? []).filter { $0.state == .pending }
    }

    func removeRequestedReviewers(owner: String, repo: String, number: Int,
                                  logins: [String]) async throws -> [GitHubReviewer] {
        let updated = try mutate(owner, repo, number: number) { item in
            let kept = (item.reviewers ?? []).filter { !($0.state == .pending && logins.contains($0.login)) }
            return item.with(reviewers: kept)
        }
        return (updated.reviewers ?? []).filter { $0.state == .pending }
    }

    func closePullRequest(owner: String, repo: String, number: Int) async throws -> GitHubItem {
        try mutate(owner, repo, number: number) { $0.with(state: .closed) }
    }

    func closeIssue(owner: String, repo: String, number: Int,
                    reason: IssueCloseReason) async throws -> GitHubItem {
        try mutate(owner, repo, number: number) { $0.with(state: .closed) }
    }

    func deleteBranch(owner: String, repo: String, branch: String) async throws {
        // No git state to touch in the fake — closing a PR then deleting its branch just succeeds.
    }
}

private extension UITestFixtures {
    /// A stable "now" for freshly written comments, one hour after the fixture base.
    static var now: Date { Date(timeIntervalSince1970: 1_700_003_600) }
}

private extension GitHubUser {
    var asActor: GitHubActor { GitHubActor(login: login, avatarURL: avatarURL) }
}

/// A value-type copy helper so the stateful fake's writes can produce a new `GitHubItem` with a few
/// fields changed without respelling all ~25 initializer arguments. `nil` means "leave unchanged".
private extension GitHubItem {
    func with(state: GitHubItemState? = nil, title: String? = nil, body: String? = nil,
              labels: [String]? = nil, assignees: [GitHubActor]? = nil,
              comments: [GitHubComment]? = nil, reviewers: [GitHubReviewer]? = nil) -> GitHubItem {
        GitHubItem(id: id, number: number, kind: kind, title: title ?? self.title,
                   state: state ?? self.state, author: author, createdAt: createdAt,
                   body: body ?? self.body, repositoryNameWithOwner: repositoryNameWithOwner,
                   labels: labels ?? self.labels, isDraft: isDraft, branch: branch,
                   additions: additions, deletions: deletions, comments: comments ?? self.comments,
                   checks: checks, files: files, tasks: tasks, parentNumber: parentNumber,
                   assignees: assignees ?? self.assignees, milestone: milestone,
                   labelColors: labelColors, mergeable: mergeable, mergeStateStatus: mergeStateStatus,
                   baseRefName: baseRefName, reviewers: reviewers ?? self.reviewers,
                   isCrossRepository: isCrossRepository)
    }
}

// MARK: - In-memory GitHub cache

/// A `GitHubCacheStore` pre-seeded from `UITestFixtures`, so the launch hydrate-then-delta path paints
/// the orgs/repos tree and a selected repo's items instantly and the fake's "live" fetch diffs to
/// unchanged. Non-throwing and best-effort like the JSON adapter it replaces in `.uiTest`.
actor InMemoryGitHubCacheStore: GitHubCacheStore {
    private var login: String?
    private var orgs: [GitHubOrg]
    private var viewerRepos: [GitHubRepo]
    private var itemsByRepoKind: [String: [GitHubItem]]

    init() {
        self.login = UITestFixtures.login
        self.orgs = UITestFixtures.orgs
        self.viewerRepos = UITestFixtures.personalRepos
        // Flatten the fixtures into per-(repoKey|kind) buckets keyed the way `saveItems` writes them.
        var buckets: [String: [GitHubItem]] = [:]
        for (repoKey, items) in UITestFixtures.items {
            for kind in [GitHubItemKind.issue, .pullRequest] {
                buckets["\(repoKey)|\(kind.rawValue)"] = items.filter { $0.kind == kind }
            }
        }
        self.itemsByRepoKind = buckets
    }

    func cachedLogin() async -> String? { login }
    func loadOrgs() async -> [GitHubOrg] { orgs }
    func loadViewerRepos() async -> [GitHubRepo] { viewerRepos }
    func loadItems(repoKey: String, kind: GitHubItemKind) async -> [GitHubItem] {
        itemsByRepoKind["\(repoKey)|\(kind.rawValue)"] ?? []
    }

    func saveOrgs(_ orgs: [GitHubOrg], viewerRepos: [GitHubRepo], login: String) async {
        self.orgs = orgs
        self.viewerRepos = viewerRepos
        self.login = login
    }

    func saveItems(_ items: [GitHubItem], repoKey: String, kind: GitHubItemKind) async {
        itemsByRepoKind["\(repoKey)|\(kind.rawValue)"] = items
    }

    func clear() async {
        login = nil
        orgs = []
        viewerRepos = []
        itemsByRepoKind = [:]
    }
}

// MARK: - In-memory connection store

/// A `ConnectionStore` seeded with sample connections/folders for `.uiTest`, kept entirely in memory
/// so the UI-test rail never reads or writes the user's real `connections.json`. Mirrors the JSON
/// adapter's contract (upsert by id, order = array order, folder delete leaves members alone).
actor InMemoryConnectionStore: ConnectionStore {
    private var connections: [Domain.Connection]
    private var folderList: [Domain.Folder]

    init(connections: [Domain.Connection] = UITestFixtures.connections,
         folders: [Domain.Folder] = UITestFixtures.folders) {
        self.connections = connections
        self.folderList = folders
    }

    func all() async throws -> [Domain.Connection] { connections }

    func save(_ connection: Domain.Connection) async throws {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
    }

    func delete(id: UUID) async throws { connections.removeAll { $0.id == id } }

    func reorder(_ orderedIDs: [UUID]) async throws {
        connections = Self.reordered(connections, by: orderedIDs, id: \Domain.Connection.id)
    }

    func folders() async throws -> [Domain.Folder] { folderList }

    func saveFolder(_ folder: Domain.Folder) async throws {
        if let idx = folderList.firstIndex(where: { $0.id == folder.id }) {
            folderList[idx] = folder
        } else {
            folderList.append(folder)
        }
    }

    func deleteFolder(id: UUID) async throws { folderList.removeAll { $0.id == id } }

    func reorderFolders(_ orderedIDs: [UUID]) async throws {
        folderList = Self.reordered(folderList, by: orderedIDs, id: \Domain.Folder.id)
    }

    /// Sort `items` into `orderedIDs`; anything omitted keeps its relative position at the end.
    private static func reordered<T>(_ items: [T], by orderedIDs: [UUID], id keyPath: KeyPath<T, UUID>) -> [T] {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element[keyPath: keyPath]] ?? (orderedIDs.count + lhs.offset)
            let r = rank[rhs.element[keyPath: keyPath]] ?? (orderedIDs.count + rhs.offset)
            return l < r
        }.map(\.element)
    }
}
