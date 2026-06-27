import Foundation

/// A user-defined folder grouping saved connections (one level — no nesting). Pure value type —
/// no UI, no transport. The order of folders in the rail is their array order in the store (the
/// `ConnectionOrdering` precedent: a stored list is the display order), so there's no `order`
/// field. A connection points at its folder via `Connection.folderId`; `nil` means ungrouped.
public struct Folder: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}
