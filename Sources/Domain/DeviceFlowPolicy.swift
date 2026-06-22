import Foundation

/// Pure timing rules for the OAuth device flow, per RFC 8628 §3.5. No clock, no sleep, no
/// network — just the arithmetic the use case shares with its tests. (Sleeping itself is I/O
/// and lives behind a port; this only decides the numbers.)
public enum DeviceFlowPolicy {
    /// The spec's default poll interval when the server omits or zeroes `interval`.
    public static let defaultInterval = 5

    /// The spec's mandated bump applied on each `slow_down` response.
    public static let slowDownIncrement = 5

    /// Clamp a server-provided interval up to the safe minimum.
    public static func effectiveInterval(_ serverInterval: Int) -> Int {
        max(defaultInterval, serverInterval)
    }

    /// Widen the interval after a `slow_down`, exactly as the spec requires (+5s).
    public static func nextInterval(current: Int) -> Int {
        current + slowDownIncrement
    }

    /// Whether the grant is still within its lifetime; the use case stops polling once this is
    /// false instead of waiting for the server's `expired_token`. A small local guard.
    public static func hasBudget(elapsedSeconds: Int, expiresIn: Int) -> Bool {
        elapsedSeconds < expiresIn
    }
}
