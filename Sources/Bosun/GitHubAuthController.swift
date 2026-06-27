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

    /// Fired when the user becomes signed-in (fresh sign-in or a restored Keychain token) and when
    /// they sign out. The App layer wires these to load/clear live GitHub data. Explicit hooks (vs.
    /// observing `Store.authState`) keep the data controller's store mutations from re-entering
    /// the auth state machine.
    var onSignedIn: (() -> Void)?
    var onSignedOut: (() -> Void)?

    init(services: GitHubAuthServices, store: Store) {
        self.services = services
        self.store = store
    }

    /// Recompute sign-in state at launch from the Keychain.
    func restore() {
        let tokenStore = services.tokenStore
        Task { @MainActor in
            let token = try? await tokenStore.load()
            if token?.isEmpty == false {
                store.authState = .signedIn
                onSignedIn?()
            } else {
                store.authState = .signedOut
            }
        }
    }

    /// Begin the device flow. Opens the sheet immediately (pending), fills in the code when it
    /// arrives, flips to `signedIn` on success, or shows a friendly error. `reason` explains a sign-in
    /// the app forced (an expired token); a user-initiated sign-in passes nil, so the sheet shows no
    /// subtitle. Setting it here — the single entry point — means a manual sign-in always clears a
    /// stale reason and recovery always sets it, with no leak path.
    func signIn(reason: String? = nil) {
        guard pollTask == nil else { return }
        store.signInReason = reason
        store.authState = .authenticatingPending
        let authenticate = services.authenticate
        pollTask = Task { @MainActor in
            do {
                try await authenticate { grant in
                    // The callback may fire off the main actor — hop back before touching Store.
                    Task { @MainActor in self.store.authState = .authenticating(grant) }
                }
                self.store.signInReason = nil
                self.store.authState = .signedIn
                self.onSignedIn?()
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
        store.signInReason = nil
        if case .signedIn = store.authState { return }
        store.authState = .signedOut
    }

    /// A confirmed 401 (the stored token is revoked/expired): drop the dead token and immediately
    /// reopen the device flow, explaining why. Guarded so a burst of 401s only recovers once — the
    /// synchronous flip out of `.signedIn` (no `await` before it) makes re-entrant calls fail the
    /// guard. Wired from `GitHubDataController.onUnauthorized`.
    func handleSessionExpired() {
        guard case .signedIn = store.authState else { return }
        reauth(reason: "Your GitHub session expired — sign in again.")
    }

    /// User-initiated reconnect: drop the current token and re-run the device flow to obtain one that
    /// sees freshly-granted org access. The fallback for when a plain same-token re-fetch (Sync) can't
    /// surface a newly-authorized org. Reuses the same recovery path as an expiry, just a different
    /// reason. Wired from the Manage-organizations sheet (#81).
    func reconnect() {
        guard case .signedIn = store.authState else { return }
        reauth(reason: "Reconnect to GitHub to apply changed organization access.")
    }

    /// Drop the token and reopen the device flow with `reason` shown as the sheet's subtitle. Shared
    /// by the 401-recovery path and the explicit reconnect. The synchronous flip out of `.signedIn`
    /// (no `await` before it) is what makes the callers' guards collapse a burst into one recovery.
    private func reauth(reason: String) {
        store.signInReason = reason
        store.authState = .authenticatingPending
        let tokenStore = services.tokenStore
        Task { @MainActor in
            try? await tokenStore.delete()
            onSignedOut?()                  // clears live data + the on-disk cache
            signIn(reason: reason)          // pollTask == nil here, so this proceeds and re-arms polling
        }
    }

    /// Sign out: delete the token, drop to signed-out.
    func signOut() {
        let tokenStore = services.tokenStore
        Task { @MainActor in
            try? await tokenStore.delete()
            store.authState = .signedOut
            onSignedOut?()
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
