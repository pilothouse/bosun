import Domain

public struct AuthenticateWithGitHubUseCase: Sendable {
    private let auth: GitHubDeviceAuth
    private let tokens: GitHubTokenStore
    private let sleeper: Sleeper
    // 3 collaborators — at the limit. The UI handoff is a callback parameter below, not a 4th
    // collaborator, so this use case stays one job.

    public init(auth: GitHubDeviceAuth, tokens: GitHubTokenStore, sleeper: Sleeper) {
        self.auth = auth
        self.tokens = tokens
        self.sleeper = sleeper
    }

    /// Drives the device flow end to end: request a device code, surface it to the UI via
    /// `onCodeIssued` (fired once, immediately, so the sheet can show the URL + user code before
    /// the long poll begins), then poll until the user authorizes (saving the token), denies, or
    /// the grant expires. Throws `AuthError` on denied/expired; returns once the token is saved.
    /// Cancelling the enclosing Task propagates through `sleeper.sleep` (Task.sleep throws
    /// `CancellationError`), unwinding the loop without saving anything.
    public func callAsFunction(
        onCodeIssued: @Sendable (DeviceCodeGrant) -> Void
    ) async throws {
        let grant = try await auth.requestDeviceCode()
        onCodeIssued(grant)

        var elapsed = 0
        var interval = DeviceFlowPolicy.effectiveInterval(grant.interval)

        while DeviceFlowPolicy.hasBudget(elapsedSeconds: elapsed, expiresIn: grant.expiresIn) {
            try await sleeper.sleep(seconds: interval)   // throws on cancel → loop unwinds
            elapsed += interval

            switch try await auth.redeemDeviceCode(grant.deviceCode) {
            case .authorized(let token):
                try await tokens.save(token)
                return
            case .pending:
                continue
            case .slowDown:
                interval = DeviceFlowPolicy.nextInterval(current: interval)
            case .denied:
                throw AuthError.denied
            case .expired:
                throw AuthError.expired
            }
        }
        throw AuthError.expired   // ran out of local budget before the server said so
    }
}
