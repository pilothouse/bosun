import Foundation

/// What iCloud sync last did (#83), as the line under the Settings checkbox reports it.
///
/// This exists because the sync path used to be entirely silent: every failure was swallowed by a
/// `try?`, both `synchronize()` return values were discarded, and nothing was logged — so a dead sync
/// and a working one looked identical, from the outside and from a diagnostics report. The decorator
/// now reports each outcome as one of these, and the App layer turns it into both a log line and this
/// hint. Pure value type: the decorator produces it, the view renders it, nothing in between.
///
/// The failure reason is carried as finished prose rather than an `Error`, because it is written for
/// the person reading the Settings pane, not for a `catch`. Sync is best-effort by design — a failure
/// here never fails the local write that triggered it — so there is nothing to recover from
/// programmatically, only something to say.
public enum SyncStatus: Sendable, Equatable {
    /// Sync is off: the opt-in default, or the user unticked the box.
    case off
    /// Turned on, first reconcile still in flight.
    case syncing
    /// The last push or merge reached iCloud, at this instant.
    case synced(Date)
    /// The last attempt did not reach iCloud. The local store is still correct and still authoritative.
    case failed(String)

    /// The hint line, or `""` when there is nothing worth saying (the label is hidden then).
    ///
    /// `now` is passed in rather than read from the clock so this stays a pure function — the relative
    /// wording below is the kind of `if` that belongs in Domain, and it is only testable if the caller
    /// owns the clock.
    public func message(now: Date) -> String {
        switch self {
        case .off:
            return ""
        case .syncing:
            return "Syncing…"
        case .synced(let at):
            // A negative interval (the clock moved backwards between the stamp and the render) falls
            // into the first branch, which is the least wrong thing to say.
            let elapsed = now.timeIntervalSince(at)
            if elapsed < 60 { return "Synced just now" }
            if elapsed < 3600 { return "Synced \(Int(elapsed / 60)) min ago" }
            return "Synced at \(at.formatted(date: .omitted, time: .shortened))"
        case .failed(let reason):
            return "Not synced — \(reason)"
        }
    }
}
