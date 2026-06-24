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
    /// The live session id at snapshot time, so restore can re-find which tab was active even when
    /// earlier tabs were dropped (a deleted connection). Ephemeral across runs — restore re-snapshots
    /// with fresh ids — so it's only meaningful within one snapshot→restore cycle. Empty for older
    /// payloads saved before this field existed.
    public let id: String
    public let kind: Kind
    public let title: String
    /// Whether the title is pinned: a user-renamed local tab, or any connection tab (#29/#30). When
    /// set, restore keeps `title` instead of letting the shell's first OSC title overwrite it.
    public let locked: Bool

    public init(id: String = "", kind: Kind, title: String, locked: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.locked = locked
    }

    /// Tolerant decoding: a payload saved by an older build (before `id`/`locked`) decodes with
    /// `id == ""` and `locked == false` instead of throwing. Mirrors `Preferences.init(from:)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.title = try container.decode(String.self, forKey: .title)
        self.locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}
