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

    public init(id: UUID, name: String, kind: ConnectionKind, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isFavorite = isFavorite
    }
}
