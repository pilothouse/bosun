import Foundation

/// Pure rule for reacting to a GitHub 401 (`unauthorized`) while signed in. A single 401 may be a
/// transient blip, so it's retried once; a second one in a row (no successful call between) confirms
/// the stored token is revoked and we re-authenticate. Once a recovery is under way — we've signed
/// out and reopened sign-in but haven't yet had a fresh success — we never re-trigger it: that guard
/// is what stops a still-bad replacement token from looping the user through sign-in.
///
/// No clock, no network: the controller owns the counters and the in-flight flag; this owns only the
/// decision, so it runs from a unit test with zero setup (like `DeviceFlowPolicy`).
public enum SessionExpiryPolicy {
    /// Back-to-back 401s (no success between) that confirm revocation rather than a one-off blip.
    /// Two means: retry the first, re-authenticate on the second.
    public static let attemptsBeforeReauth = 2

    /// What to do about a 401, given how many have arrived in a row and whether a recovery we
    /// already started is still awaiting its first successful call.
    public enum Reaction: Equatable {
        case retry            // a one-off 401 — re-attempt the failed call once
        case reauthenticate   // it repeated — sign out and reopen the device flow
        case surfaceError     // recovery already pending revalidation — show the error, don't loop
    }

    public static func reaction(consecutiveUnauthorized: Int, recoveryPending: Bool) -> Reaction {
        if recoveryPending { return .surfaceError }
        return consecutiveUnauthorized >= attemptsBeforeReauth ? .reauthenticate : .retry
    }
}
