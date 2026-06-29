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
    /// Edit an issue/PR's title/body/labels/assignees — the third write. Shares `api`'s client.
    let editItem: EditItemUseCase
    /// Request/remove a PR's reviewers (issue #70) — the fourth write. Shares `api`'s client.
    let manageReviewers: ManageReviewersUseCase
}

/// The one place allowed to choose concrete adapters and wire them into use cases.
/// Views never construct adapters — they receive a use case from here.
@MainActor
enum CompositionRoot {
    static func makeDispatchUseCase() -> DispatchAgentUseCase {
        DispatchAgentUseCase(
            store: InMemoryRunStore(),   // concrete adapters chosen here only
            runner: SSHAgentRunner(),
            events: ConsoleEventSink()
        )
    }

    static func makeConnectionServices() -> ConnectionServices {
        // Local JSON stays the offline source of truth. When the user is signed into iCloud, wrap it
        // in the syncing decorator and let every use case write through that — otherwise the use cases
        // talk to local directly (local-only, no iCloud touched). See `UbiquitousConnectionStore` (#83).
        let local = JSONFileConnectionStore(url: JSONFileConnectionStore.defaultURL())
        let icloud: UbiquitousConnectionStore? = FileManager.default.ubiquityIdentityToken != nil
            ? UbiquitousConnectionStore(local: local)
            : nil
        let store: ConnectionStore
        if let icloud { store = icloud } else { store = local }
        return ConnectionServices(
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
        let tokenStore = KeychainTokenStore()                  // concrete adapters chosen here only
        let auth = GitHubDeviceAuthClient(clientId: githubClientID(), scope: oauthScopes)
        let client = GitHubAPIClient(tokenStore: tokenStore)   // one client: reads + the two writes
        return GitHubAuthServices(
            tokenStore: tokenStore,
            authenticate: AuthenticateWithGitHubUseCase(
                auth: auth, tokens: tokenStore, sleeper: TaskSleeper()),
            api: client,                                       // shares the one token store
            cache: JSONFileGitHubCacheStore(url: JSONFileGitHubCacheStore.defaultURL()),
            addComment: AddCommentUseCase(api: client),
            mergePullRequest: MergePullRequestUseCase(api: client),
            editItem: EditItemUseCase(api: client),
            manageReviewers: ManageReviewersUseCase(api: client)
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

/// A token store backed by a fixed string — only the `BOSUN_GITHUB_TOKEN` smoke path uses it.
/// Writes are no-ops; nothing persists.
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
