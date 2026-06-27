import Foundation

/// A user-defined folder grouping saved connections (one level — no nesting). Pure value type —
/// no UI, no transport. The order of folders in the rail is their array order in the store (the
/// `ConnectionOrdering` precedent: a stored list is the display order), so there's no `order`
/// field. A connection points at its folder via `Connection.folderId`; `nil` means ungrouped.
public struct Folder: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var name: String
    /// When this folder was last written, stamped by the persistence layer for the per-record iCloud
    /// merge (see `Connection.updatedAt` and `ConnectionSyncMerge`). A missing key decodes to `nil`.
    public var updatedAt: Date?

    public init(id: UUID, name: String, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }
}
