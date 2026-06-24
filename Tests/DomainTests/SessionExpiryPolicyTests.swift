import XCTest
@testable import Domain

/// Contract tests for the pure 401-recovery rule. They describe what `SessionExpiryPolicy` promises
/// outward — retry a one-off 401, re-auth when it repeats, and never loop once a recovery is already
/// pending — not how it works inside. Don't edit a contract test to make an implementation pass — if
/// the contract is wrong, flag it.
final class SessionExpiryPolicyTests: XCTestCase {
    func testFirstUnauthorizedRetries() {
        XCTAssertEqual(SessionExpiryPolicy.reaction(consecutiveUnauthorized: 1, recoveryPending: false),
                       .retry)
        // Defensive: a zero count (shouldn't happen in practice) still isn't enough to re-auth.
        XCTAssertEqual(SessionExpiryPolicy.reaction(consecutiveUnauthorized: 0, recoveryPending: false),
                       .retry)
    }

    func testSecondConsecutiveUnauthorizedReauthenticates() {
        XCTAssertEqual(SessionExpiryPolicy.reaction(consecutiveUnauthorized: 2, recoveryPending: false),
                       .reauthenticate)
        XCTAssertEqual(SessionExpiryPolicy.reaction(consecutiveUnauthorized: 3, recoveryPending: false),
                       .reauthenticate)
    }

    func testRecoveryPendingSurfacesErrorInsteadOfLooping() {
        // Once a recovery is under way and not yet revalidated, a fresh 401 (e.g. a still-bad
        // replacement token) must not trigger another sign-out — show the error instead.
        XCTAssertEqual(SessionExpiryPolicy.reaction(consecutiveUnauthorized: 1, recoveryPending: true),
                       .surfaceError)
        XCTAssertEqual(SessionExpiryPolicy.reaction(consecutiveUnauthorized: 2, recoveryPending: true),
                       .surfaceError)
    }

    func testRetryHappensExactlyOnceBeforeReauth() {
        XCTAssertEqual(SessionExpiryPolicy.attemptsBeforeReauth, 2,
                       "one retry then re-auth: the first 401 retries, the second re-authenticates")
    }
}
