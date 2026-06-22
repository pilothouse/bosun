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
}

/// The GitHub-auth seam, bundled so the App layer gets a ready-made sign-in use case plus the
/// token store it shares — launch reads it to restore state, sign-out deletes from it. `api`
/// is the live data client, authorized with the same token store so it sees the signed-in user.
struct GitHubAuthServices {
    let tokenStore: GitHubTokenStore
    let authenticate: AuthenticateWithGitHubUseCase
    let api: GitHubAPI
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
        let store = JSONFileConnectionStore(url: JSONFileConnectionStore.defaultURL())
        return ConnectionServices(
            store: store,
            save: SaveConnectionUseCase(store: store),
            remove: RemoveConnectionUseCase(store: store)
        )
    }

    static func makePreferencesStore() -> PreferencesStore {
        UserDefaultsPreferencesStore()
    }

    static func makeGitHubAuthServices() -> GitHubAuthServices {
        let tokenStore = KeychainTokenStore()                  // concrete adapters chosen here only
        let auth = GitHubDeviceAuthClient(clientId: githubClientID(), scope: oauthScopes)
        return GitHubAuthServices(
            tokenStore: tokenStore,
            authenticate: AuthenticateWithGitHubUseCase(
                auth: auth, tokens: tokenStore, sleeper: TaskSleeper()),
            api: GitHubAPIClient(tokenStore: tokenStore)       // shares the one token store
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
