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
    /// Search a repo's issues (REST `GET /search/issues?q=repo:{owner}/{repo}+is:issue+{query}`),
    /// newest first, for the "close as duplicate" parent picker. Returns lead-field `GitHubItem`s
    /// (like `items`). Read-only with no business rule, so callers use it directly.
    func searchIssues(owner: String, repo: String, query: String) async throws -> [GitHubItem]
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
    /// Post a comment on an issue/PR and return it as GitHub stored it. The first write on this
    /// otherwise read-only port (REST `POST /repos/{owner}/{repo}/issues/{number}/comments`).
    func addComment(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment
    /// Merge a pull request per `merge` (method + optional commit text), returning the outcome
    /// GitHub reported. The second write on this port (REST
    /// `PUT /repos/{owner}/{repo}/pulls/{number}/merge`). A non-mergeable PR surfaces as
    /// `GitHubAPIError.http` from the adapter.
    func mergePullRequest(owner: String, repo: String, number: Int,
                          merge: PRMergeRequest) async throws -> PRMergeResult
    /// Edit an issue/PR's title/body/labels/assignees per `edit` and return it as GitHub stored it.
    /// The third write on this port (REST `PATCH /repos/{owner}/{repo}/issues/{number}`, which serves
    /// PRs too). Only the non-nil fields of `edit` are sent; `labels`/`assignees` *replace* the whole
    /// set. A permission denial surfaces as `GitHubAPIError.http` from the adapter.
    func editItem(owner: String, repo: String, number: Int,
                  edit: GitHubItemEdit) async throws -> GitHubItem
    /// Request reviews on a PR from `logins` and return the PR's requested (pending) reviewers after
    /// the change (REST `POST /repos/{owner}/{repo}/pulls/{number}/requested_reviewers`). The
    /// returned reviewers are all `.pending` — the REST response carries the requested set, not
    /// submitted review states. A permission denial / invalid reviewer surfaces as
    /// `GitHubAPIError.http` from the adapter.
    func requestReviewers(owner: String, repo: String, number: Int,
                          logins: [String]) async throws -> [GitHubReviewer]
    /// Cancel pending review requests on a PR for `logins` and return the requested (pending)
    /// reviewers that remain (REST `DELETE /repos/{owner}/{repo}/pulls/{number}/requested_reviewers`).
    /// Only cancels *pending* requests — a submitted review can't be removed through this endpoint.
    func removeRequestedReviewers(owner: String, repo: String, number: Int,
                                  logins: [String]) async throws -> [GitHubReviewer]
    /// Close an open pull request without merging it, returning the PR as GitHub stored it (now
    /// `closed`). Implemented as REST `PATCH /repos/{owner}/{repo}/issues/{number}` with
    /// `{"state":"closed"}` — the issues endpoint serves PRs and keeps the `pull_request` marker, so
    /// the response decodes back as a PR. A permission denial surfaces as `GitHubAPIError.http`.
    func closePullRequest(owner: String, repo: String, number: Int) async throws -> GitHubItem
    /// Close an open issue with a `state_reason` (REST `PATCH /repos/{owner}/{repo}/issues/{number}`
    /// with `{"state":"closed","state_reason":"<reason>"}`) and return the issue as GitHub stored it.
    /// A permission denial surfaces as `GitHubAPIError.http`.
    func closeIssue(owner: String, repo: String, number: Int,
                    reason: IssueCloseReason) async throws -> GitHubItem
    /// Delete a branch (git ref) in a repo (REST `DELETE /repos/{owner}/{repo}/git/refs/heads/{branch}`).
    /// Used after closing a PR to remove its head branch. A missing branch (404), a protected branch
    /// (422), or a permission denial (403) surface as `GitHubAPIError.http` from the adapter.
    func deleteBranch(owner: String, repo: String, branch: String) async throws
    /// The labels a repository defines, for the edit pane's label picker (REST
    /// `GET /repos/{owner}/{repo}/labels`). Read-only — no business rule, so callers use it directly.
    func repositoryLabels(owner: String, repo: String) async throws -> [GitHubLabel]
    /// The users assignable to a repository's issues/PRs, for the edit pane's assignee picker (REST
    /// `GET /repos/{owner}/{repo}/assignees`). Read-only, like `repositoryLabels`.
    func assignableUsers(owner: String, repo: String) async throws -> [GitHubActor]
    /// The most recent rate-limit snapshot parsed from any response's `x-ratelimit-*` headers, or
    /// `nil` if none has been seen yet. Lets the background scheduler throttle proactively (#97)
    /// rather than only reacting to a 429. Read-only and best-effort — never throws.
    func rateLimitSnapshot() async -> RateLimit?
}

public extension GitHubAPI {
    /// Default for conformers that don't track rate limits (test fakes, offline demos): no snapshot,
    /// which the scheduler reads as "budget unknown → proceed". Only the live client overrides this.
    func rateLimitSnapshot() async -> RateLimit? { nil }
}

/// Why posting a comment didn't happen before the network was even touched. `.empty` is a blank
/// (whitespace-only) body — there's nothing to post; transport/HTTP failures surface as
/// `GitHubAPIError` from the adapter, not here.
public enum AddCommentError: Error, Sendable, Equatable {
    case empty
}

/// Why editing an issue/PR didn't happen before the network was even touched. `.emptyTitle` is a
/// title edited down to blank (GitHub would reject it); `.noChanges` is an edit that changes nothing.
/// Transport/HTTP failures (including a permission denial) surface as `GitHubAPIError`, not here.
public enum EditItemError: Error, Sendable, Equatable {
    case emptyTitle
    case noChanges
}

/// Why requesting/removing reviewers didn't happen before the network was even touched. `.empty` is
/// an empty `logins` set — there's no one to request or remove; transport/HTTP failures (including a
/// permission denial) surface as `GitHubAPIError` from the adapter, not here.
public enum ManageReviewersError: Error, Sendable, Equatable {
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
    /// A GraphQL 200 whose `errors` array left no usable `data` — GitHub answered, but refused the
    /// query (SAML enforcement, a scope the token lacks, an org the app isn't authorized for). Held
    /// apart from `.transport` because the cause is the *token*, not the network, and GitHub's own
    /// message tells the user exactly what to grant. The value is that message.
    case graphQL(String)
}
