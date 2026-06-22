import Application
import Domain
import Foundation

/// Thin App-layer controller for GitHub sign-in: it parses UI intent and calls the use case,
/// then maps the outcome onto `Store.authState` so the views react. It owns the polling `Task`
/// so closing the device-flow sheet can cancel an in-flight sign-in. `@MainActor` because it
/// only ever mutates `Store` (main-thread UI state).
@MainActor
final class GitHubAuthController {
    private let services: GitHubAuthServices
    private let store: Store
    private var pollTask: Task<Void, Never>?

    init(services: GitHubAuthServices, store: Store) {
        self.services = services
        self.store = store
    }

    /// Recompute sign-in state at launch from the Keychain.
    func restore() {
        let tokenStore = services.tokenStore
        Task { @MainActor in
            let token = try? await tokenStore.load()
            store.authState = (token?.isEmpty == false) ? .signedIn : .signedOut
        }
    }

    /// Begin the device flow. Opens the sheet immediately (pending), fills in the code when it
    /// arrives, flips to `signedIn` on success, or shows a friendly error.
    func signIn() {
        guard pollTask == nil else { return }
        store.authState = .authenticatingPending
        let authenticate = services.authenticate
        pollTask = Task { @MainActor in
            do {
                try await authenticate { grant in
                    // The callback may fire off the main actor — hop back before touching Store.
                    Task { @MainActor in self.store.authState = .authenticating(grant) }
                }
                self.store.authState = .signedIn
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // User closed the sheet; `cancel()` already set the state.
                } else if let authError = error as? AuthError {
                    self.store.authState = .authError(message(for: authError))
                } else {
                    self.store.authState = .authError(message(for: .transport("\(error)")))
                }
            }
            self.pollTask = nil
        }
    }

    /// Cancel an in-flight sign-in (the sheet was closed before completion).
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        if case .signedIn = store.authState { return }
        store.authState = .signedOut
    }

    /// Sign out: delete the token, drop to signed-out.
    func signOut() {
        let tokenStore = services.tokenStore
        Task { @MainActor in
            try? await tokenStore.delete()
            store.authState = .signedOut
        }
    }

    private func message(for error: AuthError) -> String {
        switch error {
        case .denied: return "Authorization was denied. You can try signing in again."
        case .expired: return "The code expired before you finished. Please try again."
        case .transport: return "Couldn't reach GitHub. Check your connection and try again."
        }
    }
}
