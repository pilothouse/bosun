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
    static let login = "deckhand"
    static let viewer = GitHubUser(login: login, name: "Deckhand", avatarURL: nil)

    /// The instant every item is dated back from, floored to the start of the current day. It is not a
    /// hardcoded literal because the detail pane renders *relative* ages: a pinned instant reads
    /// "opened 2d ago" the week it is written and "opened 2y ago" two years later, which is exactly
    /// what the marketing screenshots must not show. Flooring to midnight keeps every run within a day
    /// identical, and each item is a fixed offset from the base, so relative order — the thing
    /// `ItemSorting` and the list assertions actually depend on — is deterministic regardless.
    private static let base = Calendar(identifier: .gregorian).startOfDay(for: Date())
    private static func hoursAgo(_ hours: Int) -> Date { base.addingTimeInterval(-Double(hours) * 3600) }

    // MARK: Repos & orgs

    static let atlasAPIRepo = GitHubRepo(id: "R_atlas_api", name: "atlas-api", owner: "harborworks",
                                         openIssues: 12, openPullRequests: 4, stargazerCount: 342)
    static let atlasWebRepo = GitHubRepo(id: "R_atlas_web", name: "atlas-web", owner: "harborworks",
                                         openIssues: 7, openPullRequests: 2, stargazerCount: 128)
    static let deckctlRepo = GitHubRepo(id: "R_deckctl", name: "deckctl", owner: "harborworks",
                                        openIssues: 3, openPullRequests: 1, stargazerCount: 41)
    static let relayRepo = GitHubRepo(id: "R_relay", name: "relay", owner: "harborworks",
                                      openIssues: 5, openPullRequests: 3, isPrivate: true)
    static let manifestRepo = GitHubRepo(id: "R_manifest", name: "manifest", owner: "harborworks",
                                         openIssues: 0, openPullRequests: 0, isPrivate: true)

    static let beaconRepo = GitHubRepo(id: "R_beacon", name: "beacon", owner: "lighthouse-labs",
                                       openIssues: 19, openPullRequests: 6, stargazerCount: 890)
    static let signalRepo = GitHubRepo(id: "R_signal", name: "signal", owner: "lighthouse-labs",
                                       openIssues: 5, openPullRequests: 0, stargazerCount: 57)
    static let foghornRepo = GitHubRepo(id: "R_foghorn", name: "foghorn", owner: "lighthouse-labs",
                                        openIssues: 2, openPullRequests: 1, isPrivate: true)

    static let dotfilesRepo = GitHubRepo(id: "R_dot", name: "dotfiles", owner: login,
                                         openIssues: 1, openPullRequests: 0, stargazerCount: 12)
    static let scratchpadRepo = GitHubRepo(id: "R_scratch", name: "scratchpad", owner: login,
                                           openIssues: 0, openPullRequests: 1, isPrivate: true)

    static let orgs: [GitHubOrg] = [
        GitHubOrg(id: "O_harborworks", login: "harborworks", name: "Harbor Works", avatarURL: nil,
                  repositories: [atlasAPIRepo, atlasWebRepo, deckctlRepo, relayRepo, manifestRepo]),
        GitHubOrg(id: "O_lighthouse", login: "lighthouse-labs", name: "Lighthouse Labs", avatarURL: nil,
                  repositories: [beaconRepo, signalRepo, foghornRepo]),
    ]

    /// The viewer's own repositories — surfaced as the synthetic personal group pinned above the orgs.
    static let personalRepos: [GitHubRepo] = [dotfilesRepo, scratchpadRepo]

    // MARK: Actors

    static let deckhand = GitHubActor(login: "deckhand")
    static let miraQ = GitHubActor(login: "mira-q")
    static let raviN = GitHubActor(login: "ravi-n")
    static let bot = GitHubActor(login: "claude[bot]")

    // MARK: The central pull request

    /// `harborworks/atlas-api#482` is the item every marketing screenshot opens on, so it is the one
    /// fixture populated across *every* detail-pane section: body + checklist, labels with colours,
    /// assignees, milestone, reviewers in two states, changed files, CI checks, comments, and a merge
    /// state that agrees with those checks (`UNSTABLE` — lint is red, so the merge box says so rather
    /// than contradicting the `ACTIONS` header).
    private static let centralBody = """
        Dispatch logs for big agent runs were buffered entirely in memory before being written, \
        which spiked RSS on the worker and occasionally OOM-killed long runs.

        This switches the writer to a streaming pipe so log lines are flushed as they arrive, \
        with a small ring buffer for the tail view.

        ### What changed
        - Replace the in-memory accumulator with a streaming `LogPipe`
        - Back-pressure when the consumer is slow instead of growing unbounded
        - Keep the last 2 MB in a ring buffer for the live tail

        ### Checklist
        - [x] Streaming writer with back-pressure
        - [x] Ring buffer for the tail view
        - [x] Unit tests for the pipe
        - [ ] Soak test on the worker box
        - [ ] Update the runbook

        Closes #468.
        """

    /// Six files whose additions and deletions sum to the `+214 −67` shown in the PR header.
    private static let centralFiles: [GitHubFile] = [
        GitHubFile(path: "Sources/Worker/LogPipe.swift", additions: 118, deletions: 12, change: .modified),
        GitHubFile(path: "Sources/Worker/RingBuffer.swift", additions: 41, deletions: 0, change: .added),
        GitHubFile(path: "Sources/Worker/DispatchRunner.swift", additions: 34, deletions: 29, change: .modified),
        GitHubFile(path: "Tests/WorkerTests/LogPipeTests.swift", additions: 18, deletions: 0, change: .added),
        GitHubFile(path: "docs/runbook.md", additions: 3, deletions: 2, change: .modified),
        GitHubFile(path: "Sources/Worker/LogAccumulator.swift", additions: 0, deletions: 24, change: .removed),
    ]

    private static let centralPR = GitHubItem(
        id: "PR_harborworks_atlas-api_482", number: 482, kind: .pullRequest,
        title: "Stream large dispatch logs instead of buffering them",
        state: .open, author: miraQ, createdAt: hoursAgo(48), body: centralBody,
        repositoryNameWithOwner: "harborworks/atlas-api",
        labels: ["performance", "needs-review"],
        branch: "fix/stream-dispatch-logs", additions: 214, deletions: 67,
        comments: [
            GitHubComment(author: deckhand, createdAt: hoursAgo(47),
                          body: "Nice — this should fix the OOMs we saw on the nightly sweep. "
                              + "Did you confirm the ring buffer survives a consumer disconnect?",
                          authorAssociation: "OWNER"),
            GitHubComment(author: miraQ, createdAt: hoursAgo(46),
                          body: "Yep, the tail reattaches cleanly. Added a test for the disconnect "
                              + "path in `LogPipeTests`.",
                          authorAssociation: "MEMBER"),
            GitHubComment(author: raviN, createdAt: hoursAgo(22),
                          body: "`swiftlint` is unhappy about the force-unwrap in `LogPipe.flush()` — "
                              + "mind guarding that? Otherwise LGTM.",
                          authorAssociation: "CONTRIBUTOR"),
            GitHubComment(author: deckhand, createdAt: hoursAgo(4),
                          body: "Good catch. Pushing a fix and kicking off the soak test on `build-box`.",
                          authorAssociation: "OWNER"),
        ],
        checks: [
            GitHubCheck(name: "build / macos", state: .success, durationSeconds: 142),
            GitHubCheck(name: "test / unit", state: .success, durationSeconds: 88),
            GitHubCheck(name: "test / integration", state: .inProgress),
            GitHubCheck(name: "lint / swiftlint", state: .failure, durationSeconds: 12),
            GitHubCheck(name: "coverage", state: .neutral, durationSeconds: 31),
        ],
        files: centralFiles,
        tasks: [
            GitHubTask(title: "Streaming writer with back-pressure", isDone: true),
            GitHubTask(title: "Ring buffer for the tail view", isDone: true),
            GitHubTask(title: "Unit tests for the pipe", isDone: true),
            GitHubTask(title: "Soak test on the worker box", isDone: false),
            GitHubTask(title: "Update the runbook", isDone: false),
        ],
        assignees: [miraQ], milestone: "1.0",
        labelColors: ["performance": "0e8a16", "needs-review": "fbca04"],
        mergeable: true, mergeStateStatus: "UNSTABLE", baseRefName: "main",
        reviewers: [
            GitHubReviewer(login: "ravi-n", state: .approved),
            GitHubReviewer(login: "deckhand", state: .pending),
        ],
        isCrossRepository: false)

    // MARK: Items (both kinds), keyed by "owner/name"

    /// Every seeded issue and PR, flat per repo. The fake filters by kind/state; the cache is seeded
    /// from the same map so a selected repo hydrates instantly.
    static let items: [String: [GitHubItem]] = [
        "harborworks/atlas-api": [
            centralPR,
            GitHubItem(id: "PR_harborworks_atlas-api_479", number: 479, kind: .pullRequest,
                       title: "Add retry budget to the SSH agent runner",
                       state: .open, author: raviN, createdAt: hoursAgo(66),
                       body: "Adds a per-run retry budget so a flaky remote doesn't burn the whole queue.",
                       repositoryNameWithOwner: "harborworks/atlas-api", labels: ["enhancement"],
                       branch: "feat/retry-budget", additions: 96, deletions: 8,
                       labelColors: ["enhancement": "a2eeef"],
                       mergeable: true, mergeStateStatus: "CLEAN", baseRefName: "main",
                       reviewers: [], isCrossRepository: false),
            GitHubItem(id: "PR_harborworks_atlas-api_475", number: 475, kind: .pullRequest,
                       title: "Bump zig to 0.15.2 in CI",
                       state: .open, author: deckhand, createdAt: hoursAgo(120),
                       body: "Keeps CI in lockstep with the pinned toolchain.",
                       repositoryNameWithOwner: "harborworks/atlas-api", labels: ["ci"],
                       branch: "chore/zig-0-15-2", additions: 4, deletions: 4,
                       labelColors: ["ci": "c5def5"],
                       mergeable: true, mergeStateStatus: "CLEAN", baseRefName: "main",
                       reviewers: [], isCrossRepository: false),
            GitHubItem(id: "PR_harborworks_atlas-api_471", number: 471, kind: .pullRequest,
                       title: "WIP: forge-agnostic dispatch (Gitea)",
                       state: .open, author: miraQ, createdAt: hoursAgo(168),
                       body: "First cut at routing dispatch through the `Forge` enum so Gitea hosts work.",
                       repositoryNameWithOwner: "harborworks/atlas-api", labels: ["wip"],
                       isDraft: true, branch: "feat/forge-gitea", additions: 320, deletions: 41,
                       labelColors: ["wip": "ededed"],
                       mergeable: nil, mergeStateStatus: "DRAFT", baseRefName: "main",
                       reviewers: [], isCrossRepository: false),
            GitHubItem(id: "I_harborworks_atlas-api_480", number: 480, kind: .issue,
                       title: "Worker OOMs on dispatch runs over ~50k log lines",
                       state: .open, author: raviN, createdAt: hoursAgo(72),
                       body: "Long agent runs grow worker RSS until the kernel kills them.\n\n"
                           + "Repro: dispatch against `atlas-api` with `--verbose`.",
                       repositoryNameWithOwner: "harborworks/atlas-api",
                       labels: ["bug", "priority:high"], assignees: [raviN],
                       labelColors: ["bug": "d73a4a", "priority:high": "b60205"]),
            GitHubItem(id: "I_harborworks_atlas-api_468", number: 468, kind: .issue,
                       title: "Stream logs instead of buffering",
                       state: .open, author: deckhand, createdAt: hoursAgo(240),
                       body: "Tracking issue for the memory blow-up. See #480 for the repro.\n\n"
                           + "- [ ] Streaming writer\n- [ ] Tail view\n",
                       repositoryNameWithOwner: "harborworks/atlas-api", labels: ["performance"],
                       tasks: [GitHubTask(title: "Streaming writer", isDone: false),
                               GitHubTask(title: "Tail view", isDone: false)],
                       milestone: "1.0", labelColors: ["performance": "0e8a16"]),
            GitHubItem(id: "I_harborworks_atlas-api_455", number: 455, kind: .issue,
                       title: "Flaky integration test: `DispatchPolicyTests.testPause`",
                       state: .open, author: miraQ, createdAt: hoursAgo(400),
                       body: "Fails ~1 in 20 on CI. Probably a timing assumption in the fake clock.",
                       repositoryNameWithOwner: "harborworks/atlas-api", labels: ["flaky-test"],
                       labelColors: ["flaky-test": "fef2c0"]),
        ],
        "lighthouse-labs/beacon": [
            GitHubItem(id: "PR_lighthouse-labs_beacon_312", number: 312, kind: .pullRequest,
                       title: "Coalesce reconnect heartbeats",
                       state: .open, author: miraQ, createdAt: hoursAgo(20),
                       body: "Buffers the first heartbeat across a reconnect so we don't false-alarm.",
                       repositoryNameWithOwner: "lighthouse-labs/beacon", labels: ["bug"],
                       branch: "fix/heartbeat-coalesce", additions: 58, deletions: 9,
                       checks: [GitHubCheck(name: "build", state: .success, durationSeconds: 61)],
                       labelColors: ["bug": "d73a4a"],
                       mergeable: true, mergeStateStatus: "CLEAN", baseRefName: "main",
                       reviewers: [GitHubReviewer(login: "deckhand", state: .pending)],
                       isCrossRepository: false),
            GitHubItem(id: "I_lighthouse-labs_beacon_311", number: 311, kind: .issue,
                       title: "Beacon drops the first heartbeat after reconnect",
                       state: .open, author: raviN, createdAt: hoursAgo(30),
                       body: "After a network blip the first heartbeat is swallowed, so the dashboard "
                           + "shows a false 'down' for one interval.",
                       repositoryNameWithOwner: "lighthouse-labs/beacon", labels: ["bug"],
                       labelColors: ["bug": "d73a4a"]),
            GitHubItem(id: "I_lighthouse-labs_beacon_305", number: 305, kind: .issue,
                       title: "Add a quiet mode to the CLI",
                       state: .open, author: deckhand, createdAt: hoursAgo(90),
                       body: "A `--quiet` flag for cron usage that only prints on failure.",
                       repositoryNameWithOwner: "lighthouse-labs/beacon",
                       labels: ["enhancement", "good first issue"],
                       labelColors: ["enhancement": "a2eeef", "good first issue": "7057ff"]),
        ],
        "deckhand/dotfiles": [
            GitHubItem(id: "I_deckhand_dotfiles_3", number: 3, kind: .issue,
                       title: "zsh prompt is slow over mosh",
                       state: .open, author: deckhand, createdAt: hoursAgo(100),
                       body: "The git status segment adds ~200ms on a high-latency link.",
                       repositoryNameWithOwner: "deckhand/dotfiles"),
        ],
        "deckhand/scratchpad": [
            GitHubItem(id: "PR_deckhand_scratchpad_9", number: 9, kind: .pullRequest,
                       title: "Archive last quarter's spikes",
                       state: .open, author: deckhand, createdAt: hoursAgo(310),
                       body: "Moves the finished spikes under `archive/`.",
                       repositoryNameWithOwner: "deckhand/scratchpad",
                       branch: "chore/archive", additions: 12, deletions: 480,
                       mergeable: true, mergeStateStatus: "CLEAN", baseRefName: "main",
                       reviewers: [], isCrossRepository: false),
        ],
    ]

    /// Same-repo blocked-by dependencies (for the "By blocked-by" grouping): repoKey → issue → its
    /// blockers. The tracking issue #468 waits on the repro in #480.
    static let blockedBy: [String: [Int: [Int]]] = ["harborworks/atlas-api": [468: [480]]]

    /// The label palette per repo, for the edit pane's label picker.
    static let labels: [String: [GitHubLabel]] = [
        "harborworks/atlas-api": [
            GitHubLabel(name: "bug", color: "d73a4a"),
            GitHubLabel(name: "enhancement", color: "a2eeef"),
            GitHubLabel(name: "performance", color: "0e8a16"),
            GitHubLabel(name: "needs-review", color: "fbca04"),
            GitHubLabel(name: "priority:high", color: "b60205"),
            GitHubLabel(name: "flaky-test", color: "fef2c0"),
            GitHubLabel(name: "ci", color: "c5def5"),
            GitHubLabel(name: "wip", color: "ededed"),
        ],
        "lighthouse-labs/beacon": [
            GitHubLabel(name: "bug", color: "d73a4a"),
            GitHubLabel(name: "enhancement", color: "a2eeef"),
            GitHubLabel(name: "good first issue", color: "7057ff"),
        ],
    ]

    /// The users assignable per repo, for the edit pane's assignee picker.
    static let assignableUsers: [String: [GitHubActor]] = [
        "harborworks/atlas-api": [deckhand, miraQ, raviN, bot],
        "harborworks/atlas-web": [deckhand, miraQ],
        "lighthouse-labs/beacon": [deckhand, raviN],
        "deckhand/dotfiles": [deckhand],
        "deckhand/scratchpad": [deckhand],
    ]

    // MARK: Connections

    // `Connection`/`Folder` are qualified `Domain.*` throughout: the Bosun module has its own
    // presentation `Connection` (id: String) that would otherwise shadow the Domain entity here.
    static let harborFolder = Domain.Folder(id: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!,
                                            name: "Harbor")
    static let lighthouseFolder = Domain.Folder(id: UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!,
                                                name: "Lighthouse")

    static let connections: [Domain.Connection] = [
        Domain.Connection(id: UUID(uuidString: "A1111111-0000-4000-8000-000000000001")!,
                          name: "Harbor · API",
                          kind: .ssh(host: "10.20.0.11", port: 22, user: "deploy"),
                          isFavorite: true, customCommand: "tmux new -A -s api",
                          folderId: harborFolder.id),
        Domain.Connection(id: UUID(uuidString: "A1111111-0000-4000-8000-000000000002")!,
                          name: "Harbor · Worker",
                          kind: .ssh(host: "10.20.0.12", port: 22, user: "deploy"),
                          isFavorite: true, folderId: harborFolder.id),
        Domain.Connection(id: UUID(uuidString: "A1111111-0000-4000-8000-000000000003")!,
                          name: "build-box",
                          kind: .ssh(host: "build.lighthouse.internal", port: 2222, user: "ci"),
                          folderId: lighthouseFolder.id),
        // A neutral, short path rather than a real checkout: the rail renders a connection's path as
        // its subtitle, so anything machine-specific would leak straight into a screenshot. Create it
        // (`mkdir -p /tmp/beacon`) before shooting if you want the terminal tab to open there.
        Domain.Connection(id: UUID(uuidString: "A1111111-0000-4000-8000-000000000004")!,
                          name: "beacon",
                          kind: .localFolder(path: "/tmp/beacon"),
                          folderId: lighthouseFolder.id),
        Domain.Connection(id: UUID(uuidString: "A1111111-0000-4000-8000-000000000005")!,
                          name: "dotfiles",
                          kind: .localFolder(path: NSHomeDirectory())),
    ]

    static let folders: [Domain.Folder] = [harborFolder, lighthouseFolder]
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
