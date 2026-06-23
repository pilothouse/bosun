import Foundation

/// The persisted shape of one open terminal tab, so the dock can reopen tabs on relaunch. A pure
/// value type — the App layer maps it to a live libghostty surface (a local shell, or a connection
/// re-resolved by id and reconnected). Session UUIDs are ephemeral, so a connection tab is keyed by
/// its `Connection.id` rather than the session id; a tab whose connection no longer exists is
/// skipped on restore. See `Preferences.openTabs`.
public struct TerminalTabState: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case local
        case connection(id: String)
    }
    public let kind: Kind
    public let title: String

    public init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}
