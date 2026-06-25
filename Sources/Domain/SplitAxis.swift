import Foundation

/// How the center column splits the issue/PR **detail** from the docked **terminal** — the user's
/// choice, persisted in `Preferences.splitAxis`. `vertical` stacks the detail above the terminal
/// (today's layout); `horizontal` places them side by side (detail left, terminal right). The raw
/// values are stable storage keys, *not* display labels, so a label change never invalidates a
/// stored value; the App layer maps them to titlebar glyphs. Mirrors the storage/display split of
/// `ItemSortField` and `RepoOrderingMode`.
public enum SplitAxis: String, Sendable, Codable, CaseIterable {
    case vertical, horizontal

    /// The orientation used until the user picks one — the stacked detail-over-terminal layout
    /// the app has always shipped, so an upgrade looks unchanged.
    public static let `default`: SplitAxis = .vertical

    /// The other orientation — what the titlebar toggle switches to.
    public var toggled: SplitAxis { self == .vertical ? .horizontal : .vertical }
}
