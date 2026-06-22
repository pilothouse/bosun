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
/// token store it shares — launch reads it to restore state, sign-out deletes from it.
struct GitHubAuthServices {
    let tokenStore: GitHubTokenStore
    let authenticate: AuthenticateWithGitHubUseCase
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
        let auth = GitHubDeviceAuthClient(clientId: githubClientID())
        return GitHubAuthServices(
            tokenStore: tokenStore,
            authenticate: AuthenticateWithGitHubUseCase(
                auth: auth, tokens: tokenStore, sleeper: TaskSleeper())
        )
    }

    /// The OAuth/GitHub-App client_id. Read from `BOSUN_GITHUB_CLIENT_ID` so a different app can be
    /// swapped in without a rebuild; falls back to the project's registered GitHub App. (A device-
    /// flow client_id is not a secret — it's safe to ship as the default.)
    private static func githubClientID() -> String {
        ProcessInfo.processInfo.environment["BOSUN_GITHUB_CLIENT_ID"] ?? "Iv23liJR8FXU8M894PsK"
    }
}

// An AppKit controller stays thin — it parses input and calls the use case:
//
//   @MainActor final class DispatchController {
//       private let dispatch = CompositionRoot.makeDispatchUseCase()
//       func onDispatchTapped(_ run: AgentRun) {
//           Task { try await dispatch(run: run, maxConcurrentPerOrg: 3, repoIsPaused: false) }
//       }
//   }
