import Domain
import Foundation

public protocol RunStore: Sendable {
    func activeRunCount(forOrg org: String) async throws -> Int
    func save(_ run: AgentRun) async throws
}

public protocol AgentRunner: Sendable {
    func start(_ run: AgentRun) async throws
}

public protocol RunEventSink: Sendable {
    func emit(_ event: RunEvent) async
}

public enum RunEvent: Sendable {
    case dispatched(runID: UUID)
    case rejected(runID: UUID, reason: String)
}

/// Persistence seam for saved connections and the user folders that group them. The use cases talk
/// to this port; a concrete adapter (a JSON file, later a database) lives in Infrastructure and is
/// wired in `CompositionRoot`. `save` upserts by id; `reorder` sets the persisted order — the stored
/// order is the rail's display order, so a drag-reorder writes it through here. Folders are a
/// parallel collection on the same store (so they persist in one file alongside connections);
/// `Connection.folderId` ties a connection to a folder.
public protocol ConnectionStore: Sendable {
    func all() async throws -> [Connection]
    func save(_ connection: Connection) async throws
    func delete(id: UUID) async throws
    /// Re-sort the stored connections into `orderedIDs`. Ids not present are ignored; any stored
    /// connection the list omits keeps its current relative position at the end.
    func reorder(_ orderedIDs: [UUID]) async throws
    /// The user folders, in their persisted (display) order.
    func folders() async throws -> [Folder]
    /// Upsert a folder by id.
    func saveFolder(_ folder: Folder) async throws
    /// Remove a folder record. Member connections are *not* touched here — the cascade (deleting a
    /// folder's connections) is the use case's job, so the port stays a dumb persistence seam.
    func deleteFolder(id: UUID) async throws
    /// Re-sort the stored folders into `orderedIDs`, with the same omitted-keeps-its-place rule as
    /// `reorder`.
    func reorderFolders(_ orderedIDs: [UUID]) async throws
}

/// Persistence seam for UI preferences. The App layer loads once at launch and saves a
/// snapshot whenever a tracked field changes; a concrete adapter (UserDefaults) lives in
/// Infrastructure and is wired in `CompositionRoot`. Deliberately non-throwing: a failed
/// preference write must never surface an error to the user — `load` falls back to defaults
/// and `save` is best-effort.
public protocol PreferencesStore: Sendable {
    func load() async -> Preferences
    func save(_ preferences: Preferences) async
}

/// Transport seam for GitHub's OAuth device flow. Two calls, no state: ask for a device code,
/// then redeem it. The concrete adapter (URLSession → github.com) lives in Infrastructure and
/// is wired in `CompositionRoot`.
public protocol GitHubDeviceAuth: Sendable {
    func requestDeviceCode() async throws -> DeviceCodeGrant
    func redeemDeviceCode(_ deviceCode: String) async throws -> DeviceTokenPoll
}

/// Persistence seam for the OAuth access token. The concrete adapter (a Keychain generic-password
/// item) lives in Infrastructure. `load` returns nil when signed out; `delete` is the sign-out.
public protocol GitHubTokenStore: Sendable {
    func load() async throws -> String?
    func save(_ token: String) async throws
    func delete() async throws
}

/// Injectable delay so the polling use case waits in production but runs instantly in tests.
/// The real adapter wraps `Task.sleep` (which throws on cancel — that's how a cancelled
/// sign-in stops mid-poll); a test fake returns immediately.
public protocol Sleeper: Sendable {
    func sleep(seconds: Int) async throws
}

/// Why a sign-in didn't complete. `.denied`/`.expired` are normal user/timeout outcomes the
/// sheet renders as a friendly message; `.transport` wraps an underlying network/HTTP failure.
public enum AuthError: Error, Sendable, Equatable {
    case denied
    case expired
    case transport(String)
}

/// Read seam for live GitHub data. One cohesive port over both transports the adapter uses
/// (GraphQL for the nested org/repo/item fetches, REST where it's simpler), so a use case
/// takes it as a single collaborator. The concrete adapter (`GitHubAPIClient`, URLSession →
/// api.github.com, injected the Keychain token) lives in Infrastructure and is wired in
/// `CompositionRoot`. Every method returns pure `Domain` entities — the App layer adds the UI.
public protocol GitHubAPI: Sendable {
    /// The authenticated user behind the stored token.
    func currentUser() async throws -> GitHubUser
    /// The viewer's organizations, each with its repositories and their open-work counts.
    func organizations() async throws -> [GitHubOrg]
    /// The viewer's own (user-owned) repositories with their open-work counts — the personal repos
    /// that live under the user, not an organization. Lets a no-org account still see live data.
    func viewerRepositories() async throws -> [GitHubRepo]
    /// Issues or pull requests in a repo (lead fields only — no comments/checks), restricted to
    /// `states`. Open-only is the cheap default and fetches the full set; a broader selection bounds
    /// closed/merged history (see `GitHubItemList.reachedHistoryCap`).
    func items(owner: String, repo: String, kind: GitHubItemKind,
               states: Set<GitHubItemState>) async throws -> GitHubItemList
    /// Open issues or PRs across many of `owner`'s `repos` in as few GraphQL round-trips as
    /// possible: one request aliases a fixed batch of repos (the rate-limit win over one `items`
    /// call per repo), paging only the repos whose first page overflowed. Returns one
    /// `GitHubRepoItems` per repo that resolved — an inaccessible repo is omitted, leaving its
    /// cache untouched — so it's the aggregate org view's primary fetch, with per-repo `items`
    /// calls as the fallback. `states` restricts like `items`.
    func batchItems(owner: String, repos: [String], kind: GitHubItemKind,
                    states: Set<GitHubItemState>) async throws -> [GitHubRepoItems]
    /// One item fully hydrated: body-derived tasks, comments, and (for PRs) check runs.
    func itemDetail(owner: String, repo: String, number: Int) async throws -> GitHubItem
    /// Numbers of same-repo issues that block this one — GitHub's native issue dependencies
    /// (REST `GET /repos/{owner}/{repo}/issues/{number}/dependencies/blocked_by`). One call per
    /// issue, so callers fetch lazily (only for the active "By blocked-by" grouping). Cross-repo
    /// blockers and any when the feature is unavailable are dropped, yielding an empty list.
    func issueDependencies(owner: String, repo: String, number: Int) async throws -> [Int]
    /// Post a comment on an issue/PR and return it as GitHub stored it. The one write on this
    /// otherwise read-only port (REST `POST /repos/{owner}/{repo}/issues/{number}/comments`).
    func addComment(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment
}

/// Why posting a comment didn't happen before the network was even touched. `.empty` is a blank
/// (whitespace-only) body — there's nothing to post; transport/HTTP failures surface as
/// `GitHubAPIError` from the adapter, not here.
public enum AddCommentError: Error, Sendable, Equatable {
    case empty
}

/// Persistence seam for a local copy of the viewer's GitHub data, so the UI hydrates instantly on
/// launch and a refresh applies a `GitHubDelta` instead of a full replace. Deliberately non-throwing
/// and best-effort like `PreferencesStore`: a cache miss or corrupt file reads as empty and a failed
/// write is dropped — caching must never crash the app or block the live fetch. The cache is scoped
/// to a single viewer `login`; `saveOrgs` with a different login drops the previous account's data,
/// and `clear()` is the sign-out wipe. The concrete adapter (a JSON file under Application Support)
/// lives in Infrastructure and is wired in `CompositionRoot`.
public protocol GitHubCacheStore: Sendable {
    /// The login the cached data belongs to, or nil when the cache is empty — lets the caller spot
    /// an account switch and decide whether to merge against or replace the cached rows.
    func cachedLogin() async -> String?
    func loadOrgs() async -> [GitHubOrg]
    func loadViewerRepos() async -> [GitHubRepo]
    func loadItems(repoKey: String, kind: GitHubItemKind) async -> [GitHubItem]
    /// Replace the cached org panel (orgs + the viewer's own repos) for `login`. Saving a login that
    /// differs from the stored one first drops the previous account's orgs *and* per-repo items.
    func saveOrgs(_ orgs: [GitHubOrg], viewerRepos: [GitHubRepo], login: String) async
    func saveItems(_ items: [GitHubItem], repoKey: String, kind: GitHubItemKind) async
    /// Drop everything (sign-out).
    func clear() async
}

/// Why a GitHub API call failed, in terms the App layer can act on rather than raw HTTP. The
/// adapter maps status codes and decode failures onto these; the token is never echoed back.
public enum GitHubAPIError: Error, Sendable, Equatable {
    case unauthorized                  // 401, or no token stored — the user must (re)authenticate
    case rateLimited(resetAt: Date?)   // 403 with the request budget exhausted; resets at `resetAt`
    case notFound                      // 404 — repo/item missing or not visible to this token
    case http(status: Int)             // any other non-2xx response
    case decoding(String)              // a 2xx body that didn't match the expected shape
    case transport(String)             // URLSession/connection failure
}
