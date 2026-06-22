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

/// Persistence seam for saved connections. The use cases talk to this port; a concrete
/// adapter (a JSON file, later a database) lives in Infrastructure and is wired in
/// `CompositionRoot`. `save` upserts by id.
public protocol ConnectionStore: Sendable {
    func all() async throws -> [Connection]
    func save(_ connection: Connection) async throws
    func delete(id: UUID) async throws
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
    /// Open issues or pull requests in a repo (lead fields only — no comments/checks).
    func items(owner: String, repo: String, kind: GitHubItemKind) async throws -> [GitHubItem]
    /// One item fully hydrated: body-derived tasks, comments, and (for PRs) check runs.
    func itemDetail(owner: String, repo: String, number: Int) async throws -> GitHubItem
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
