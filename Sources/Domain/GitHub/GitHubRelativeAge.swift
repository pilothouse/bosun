import Foundation

/// Pure rule that collapses an elapsed duration into the compact "4m ago" / "3h ago" / "2w ago"
/// label the issue/PR lists and comments show. `now` is a parameter (not `Date()`) so the
/// bucketing is deterministic and testable. Buckets use integer division — "90s ago" reads as
/// "1m ago", not "1.5m". A timestamp in the future (clock skew) degrades to "just now".
public enum GitHubRelativeAge {
    public static func compact(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }
}
