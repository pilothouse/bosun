import Application
import Domain
import Foundation
import Infrastructure

/// The connection persistence seam, bundled so the App layer receives ready-made use cases
/// instead of constructing adapters. The store is shared by both use cases so they read and
/// write the same file.
struct ConnectionServices {
    let store: ConnectionStore
    let save: SaveConnectionUseCase
    let remove: RemoveConnectionUseCase
    let reorder: ReorderConnectionsUseCase
    let saveFolder: SaveFolderUseCase
    let removeFolder: RemoveFolderUseCase
    let moveToFolder: MoveConnectionToFolderUseCase
    let reorderFolders: ReorderFoldersUseCase
    /// The iCloud sync decorator wrapping `store`, present only when the user is signed into iCloud
    /// (#83). The App layer drives it: `start` wires the remote-change reload, `setEnabled` follows
    /// the Settings toggle. `nil` means local-only — no iCloud, no behavior change.
    let icloud: UbiquitousConnectionStore?
}

/// The GitHub-auth seam, bundled so the App layer gets a ready-made sign-in use case plus the
/// token store it shares — launch reads it to restore state, sign-out deletes from it. `api`
/// is the live data client, authorized with the same token store so it sees the signed-in user.
struct GitHubAuthServices {
    let tokenStore: GitHubTokenStore
    let authenticate: AuthenticateWithGitHubUseCase
    let api: GitHubAPI
    /// Local cache of the fetched data so the data controller can hydrate the UI instantly on launch
    /// and apply a delta on refresh. Cleared on sign-out alongside the token.
    let cache: GitHubCacheStore
    /// Post a comment on an issue/PR — the first write. Shares `api`'s client (same token).
    let addComment: AddCommentUseCase
    /// Merge a pull request — the second write. Shares `api`'s client (same token).
    let mergePullRequest: MergePullRequestUseCase
    /// Close a PR without merging and (optionally) delete its head branch. Shares `api`'s client.
    let closePullRequest: ClosePullRequestUseCase
    /// Close an open issue with a state reason (completed / not planned / duplicate). Shares `api`'s client.
    let closeIssue: CloseIssueUseCase
    /// Edit an issue/PR's title/body/labels/assignees — the third write. Shares `api`'s client.
    let editItem: EditItemUseCase
    /// Request/remove a PR's reviewers (issue #70) — the fourth write. Shares `api`'s client.
    let manageReviewers: ManageReviewersUseCase
}

/// The one place allowed to choose concrete adapters and wire them into use cases.
/// Views never construct adapters — they receive a use case from here.
@MainActor
enum CompositionRoot {
    /// The launch mode, resolved once from the environment (see `AppMode`). This is the single place
    /// the `BOSUN_UI_TEST`/`BOSUN_PERF_SEED` flags are read; every adapter choice below and the perf
    /// branch in `AppDelegate` reads *this* rather than re-parsing the environment.
    static let appMode = AppMode.resolve(environment: ProcessInfo.processInfo.environment)

    /// The fixed, non-empty token handed to the in-memory `StaticTokenStore` in the offline modes so
    /// `auth.restore()` sees a token and flips to `.signedIn` without the Keychain ever being read.
    private static let offlineTestToken = "ui-test-token"

    static func makeDispatchUseCase() -> DispatchAgentUseCase {
        DispatchAgentUseCase(
            store: InMemoryRunStore(),   // concrete adapters chosen here only
            runner: SSHAgentRunner(),
            events: ConsoleEventSink()
        )
    }

    static func makeConnectionServices() -> ConnectionServices {
        // UI-test mode keeps connections entirely in memory so it never reads or writes the user's real
        // `connections.json` (and skips iCloud); every other run uses the on-disk store.
        if appMode == .uiTest {
            return connectionServices(store: InMemoryConnectionStore(), icloud: nil)
        }
        // Local JSON stays the offline source of truth. When the user is signed into iCloud, wrap it
        // in the syncing decorator and let every use case write through that — otherwise the use cases
        // talk to local directly (local-only, no iCloud touched). See `UbiquitousConnectionStore` (#83).
        let local = JSONFileConnectionStore(url: JSONFileConnectionStore.defaultURL())
        let icloud: UbiquitousConnectionStore? = FileManager.default.ubiquityIdentityToken != nil
            ? UbiquitousConnectionStore(local: local)
            : nil
        let store: ConnectionStore = icloud ?? local
        return connectionServices(store: store, icloud: icloud)
    }

    /// Build the connection use-case bundle over one shared `store` (both use cases read/write the
    /// same adapter). Factored out so the on-disk and in-memory (`.uiTest`) paths wire identically.
    private static func connectionServices(store: ConnectionStore,
                                           icloud: UbiquitousConnectionStore?) -> ConnectionServices {
        ConnectionServices(
            store: store,
            save: SaveConnectionUseCase(store: store),
            remove: RemoveConnectionUseCase(store: store),
            reorder: ReorderConnectionsUseCase(store: store),
            saveFolder: SaveFolderUseCase(store: store),
            removeFolder: RemoveFolderUseCase(store: store),
            moveToFolder: MoveConnectionToFolderUseCase(store: store),
            reorderFolders: ReorderFoldersUseCase(store: store),
            icloud: icloud
        )
    }

    static func makePreferencesStore() -> PreferencesStore {
        UserDefaultsPreferencesStore()
    }

    static func makeGitHubAuthServices() -> GitHubAuthServices {
        switch appMode {
        case .normal:
            // The shipping path: Keychain token + live client (one client serves reads and writes).
            let tokenStore = KeychainTokenStore()
            return assembleAuthServices(tokenStore: tokenStore,
                                        api: GitHubAPIClient(tokenStore: tokenStore),
                                        cache: JSONFileGitHubCacheStore(url: JSONFileGitHubCacheStore.defaultURL()))
        case .uiTest:
            // Fully offline: an in-memory token (Keychain never read), a stateful fake client shared by
            // reads and writes so mutations persist, and a cache pre-seeded from the same fixtures.
            let fake = FakeGitHubAPI()
            return assembleAuthServices(tokenStore: StaticTokenStore(token: offlineTestToken),
                                        api: fake, cache: InMemoryGitHubCacheStore())
        case .perfSeed:
            // Perf profiling loads the heavy on-disk cache and never fetches (see `loadFromCacheForPerf`).
            // The live client is present but unused; the in-memory token keeps it Keychain-safe too.
            let tokenStore = StaticTokenStore(token: offlineTestToken)
            return assembleAuthServices(tokenStore: tokenStore,
                                        api: GitHubAPIClient(tokenStore: tokenStore),
                                        cache: JSONFileGitHubCacheStore(url: JSONFileGitHubCacheStore.defaultURL()))
        }
    }

    /// Assemble the GitHub-auth bundle from a chosen token store, data client, and cache. `api` is
    /// shared by the read path *and* every write use case (one client, one token), so a `.uiTest`
    /// write mutates the same fake the reads project.
    private static func assembleAuthServices(tokenStore: GitHubTokenStore, api: GitHubAPI,
                                             cache: GitHubCacheStore) -> GitHubAuthServices {
        let auth = GitHubDeviceAuthClient(clientId: githubClientID(), scope: oauthScopes)
        return GitHubAuthServices(
            tokenStore: tokenStore,
            authenticate: AuthenticateWithGitHubUseCase(
                auth: auth, tokens: tokenStore, sleeper: TaskSleeper()),
            api: api,
            cache: cache,
            addComment: AddCommentUseCase(api: api),
            mergePullRequest: MergePullRequestUseCase(api: api),
            closePullRequest: ClosePullRequestUseCase(api: api),
            closeIssue: CloseIssueUseCase(api: api),
            editItem: EditItemUseCase(api: api),
            manageReviewers: ManageReviewersUseCase(api: api)
        )
    }

    /// A GitHub data client authorized with an explicit token rather than the Keychain. Used
    /// only by the `BOSUN_API_SMOKE` dev probe so a live call can run from a PAT without an
    /// interactive device-flow sign-in. Not part of the normal app path.
    static func makeGitHubAPI(token: String) -> GitHubAPI {
        GitHubAPIClient(tokenStore: StaticTokenStore(token: token))
    }

    /// Scopes requested at device-flow sign-in. `read:org` is the one that matters here: without
    /// it `viewer.organizations` returns only orgs whose membership is *public* (this is why the
    /// app showed 7 of ~20). `repo` covers private repositories and their open issue/PR counts;
    /// `read:user` covers the viewer's profile. These take effect ONLY for an **OAuth App** — a
    /// GitHub App ignores `scope` and derives access from its per-org installation instead.
    private static let oauthScopes = "read:org repo read:user"

    /// The OAuth App client_id. Read from `BOSUN_GITHUB_CLIENT_ID` so a different app can be swapped
    /// in without a rebuild. For the scopes above to apply this MUST be an OAuth App
    /// (github.com/settings/developers → New OAuth App, with "Enable Device Flow" checked), not a
    /// GitHub App. (A device-flow client_id is not a secret — it's safe to ship as the default.)
    private static func githubClientID() -> String {
        ProcessInfo.processInfo.environment["BOSUN_GITHUB_CLIENT_ID"] ?? "Ov23liOrAKfzcXed8ucm"
    }

    /// The GitHub page where the user grants/revokes this OAuth App's org access, built from the
    /// *resolved* client id so an overridden app (`BOSUN_GITHUB_CLIENT_ID`) points at the right page.
    /// The Manage-organizations sheet opens this so the user can change access without leaving Bosun.
    static func githubConnectionsURL() -> URL {
        GitHubOAuthApp.connectionsURL(clientID: githubClientID())
    }
}

/// A token store backed by a fixed string. Used by the `BOSUN_GITHUB_TOKEN` smoke path and by the
/// offline `.uiTest`/`.perfSeed` modes, where a fixed non-empty token makes `auth.restore()` see a
/// signed-in session without ever reading the Keychain. Writes are no-ops; nothing persists.
private struct StaticTokenStore: GitHubTokenStore {
    let token: String
    func load() async throws -> String? { token }
    func save(_ token: String) async throws {}
    func delete() async throws {}
}

// An AppKit controller stays thin — it parses input and calls the use case:
//
//   @MainActor final class DispatchController {
//       private let dispatch = CompositionRoot.makeDispatchUseCase()
//       func onDispatchTapped(_ run: AgentRun) {
//           Task { try await dispatch(run: run, maxConcurrentPerOrg: 3, repoIsPaused: false) }
//       }
//   }
