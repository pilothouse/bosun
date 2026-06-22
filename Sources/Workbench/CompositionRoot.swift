import Application
import Domain
import Infrastructure

/// The connection persistence seam, bundled so the App layer receives ready-made use cases
/// instead of constructing adapters. The store is shared by both use cases so they read and
/// write the same file.
struct ConnectionServices {
    let store: ConnectionStore
    let save: SaveConnectionUseCase
    let remove: RemoveConnectionUseCase
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
}

// An AppKit controller stays thin — it parses input and calls the use case:
//
//   @MainActor final class DispatchController {
//       private let dispatch = CompositionRoot.makeDispatchUseCase()
//       func onDispatchTapped(_ run: AgentRun) {
//           Task { try await dispatch(run: run, maxConcurrentPerOrg: 3, repoIsPaused: false) }
//       }
//   }
