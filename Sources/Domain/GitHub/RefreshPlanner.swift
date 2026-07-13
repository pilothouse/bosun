import Foundation

/// The pure scheduling policy behind opt-in background refresh (#97). Given the clock, when each
/// unit was last refreshed, which units currently make sense, and the last-seen rate-limit budget,
/// it decides *which single unit* to refresh next — or nothing. This is the "if" Domain owns: the
/// App-layer timer just fires a fixed short tick and asks this rule what (if anything) to do, so the
/// "gradual, never spam" behaviour lives in one deterministic, unit-tested place instead of the
/// timer callback.
///
/// The rule: refresh at most one unit per tick, round-robin (oldest-due-first) over the applicable
/// units, gated by a per-unit staleness `interval`; pause entirely while the rate-limit budget is
/// below a safety floor and its window hasn't reset yet. Deterministic — `now`, `lastRefreshed`, and
/// `rateLimit` are all inputs, so there's no hidden clock.
public enum RefreshPlanner {
    /// The refreshable scopes, round-robined one per tick. `orgList` is the org/repo panel (one
    /// bounded fetch that refreshes every org's open counts); `currentItems` is the open scope's
    /// PRs/issues. `String`-backed + `CaseIterable` so the App layer can key `lastRefreshed` by it
    /// and the tie-break order is stable.
    public enum Unit: String, Sendable, Equatable, CaseIterable {
        case orgList
        case currentItems
    }

    /// How often the App-layer timer ticks and asks for the next unit. Deliberately shorter than any
    /// staleness interval so both units can be served within one window — they stagger across ticks
    /// (one per tick) rather than all firing at once.
    public static let tickCadence: TimeInterval = 60

    /// Pause auto-refresh once fewer than this many calls remain in the budget, so an interactive
    /// action (a manual refresh, opening a repo) still has headroom.
    public static let safetyFloor = 100

    /// The unit to refresh at `now`, or `nil` when nothing is due or the budget is too low.
    ///
    /// - `interval`: how long a unit stays fresh before it's due again.
    /// - `lastRefreshed`: when each unit was last fetched; a missing entry counts as never (due now).
    /// - `applicable`: the units that currently make sense (e.g. `currentItems` only when a scope is open).
    /// - `rateLimit`: the last-seen budget, or `nil` when none has been observed yet (treated as available).
    public static func next(
        now: Date,
        interval: TimeInterval,
        lastRefreshed: [Unit: Date],
        applicable: [Unit],
        rateLimit: RateLimit?,
        safetyFloor: Int = RefreshPlanner.safetyFloor
    ) -> Unit? {
        // Proactive throttle: pause while the budget is low and the window hasn't reset yet. Once
        // `now >= resetAt` GitHub has refilled the budget, so a stale low snapshot no longer blocks —
        // the next successful fetch will replace it with a healthy one.
        if let rateLimit, rateLimit.remaining < safetyFloor, now < rateLimit.resetAt {
            return nil
        }
        // The oldest due unit wins (never-refreshed = infinitely old); ties resolve by `allCases`
        // order for determinism. Iterating `allCases` (not `applicable`) keeps that tie-break stable
        // regardless of the caller's argument order.
        var best: Unit?
        var bestStamp = Date.distantFuture
        for unit in Unit.allCases where applicable.contains(unit) {
            let last = lastRefreshed[unit] ?? .distantPast
            guard now.timeIntervalSince(last) >= interval else { continue }   // still fresh
            if last < bestStamp {
                best = unit
                bestStamp = last
            }
        }
        return best
    }
}
