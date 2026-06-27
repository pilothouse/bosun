import Foundation

/// How a connection reaches its workspace. The associated values are the connection's
/// defining configuration — what gets persisted — not its live status.
public enum ConnectionKind: Sendable, Equatable, Codable {
    case ssh(host: String, port: Int, user: String?)
    case localFolder(path: String)
}

/// A saved connection: an SSH remote or a local folder the operator works against.
/// Pure value type — no UI, no transport. The App layer maps it to a presentation model.
public struct Connection: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var isFavorite: Bool
    /// An optional command run after connecting (SSH only today, e.g. `tmux new -n dev`).
    /// Synthesized `Codable` decodes a missing key as `nil`, so older stores load unchanged.
    public var customCommand: String?
    /// The user folder this connection belongs to, or `nil` when ungrouped. Like `customCommand`,
    /// a missing key decodes to `nil`, so an existing `connections.json` (written before folders)
    /// loads with every connection ungrouped — the folders migration. See `ConnectionGrouping`.
    public var folderId: UUID?

    public init(id: UUID, name: String, kind: ConnectionKind, isFavorite: Bool = false,
                customCommand: String? = nil, folderId: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isFavorite = isFavorite
        self.customCommand = customCommand
        self.folderId = folderId
    }
}
