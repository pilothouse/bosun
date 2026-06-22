import Foundation

/// GitHub's rate-limit snapshot, parsed from the `x-ratelimit-*` response headers. Pure: the
/// adapter reads the headers off a response and asks this type whether the budget is spent —
/// the one branch that tells a 403-with-no-budget apart from a 403-forbidden.
public struct RateLimit: Sendable, Equatable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date

    public init(limit: Int, remaining: Int, resetAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }

    /// True once the window has no calls left — the signal to surface `.rateLimited(resetAt:)`.
    public var isExhausted: Bool { remaining <= 0 }

    /// Build a snapshot from response headers, or nil if any of the three fields is missing.
    /// Lookup is case-insensitive because header casing varies across platforms.
    public static func parse(headers: [String: String]) -> RateLimit? {
        func value(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let limit = value("x-ratelimit-limit").flatMap({ Int($0) }),
              let remaining = value("x-ratelimit-remaining").flatMap({ Int($0) }),
              let reset = value("x-ratelimit-reset").flatMap({ TimeInterval($0) }) else {
            return nil
        }
        return RateLimit(limit: limit, remaining: remaining,
                         resetAt: Date(timeIntervalSince1970: reset))
    }
}
