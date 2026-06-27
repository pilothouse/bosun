import Foundation

/// One rendered band of the connection rail: the pinned Favorites, a user `Folder`, or the
/// catch-all Ungrouped. Pure presentation-agnostic grouping — the App layer maps each section's
/// `Connection`s to its view models and draws the headers.
public struct ConnectionSection: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case favorites
        case folder(Folder)
        case ungrouped
    }

    public let kind: Kind
    public let connections: [Connection]

    public init(kind: Kind, connections: [Connection]) {
        self.kind = kind
        self.connections = connections
    }
}

/// Pure rule for how saved connections are bucketed into rail sections, replacing the old
/// type-based (SSH/local) split. One level of user folders, no nesting: Favorites is pinned first,
/// then one section per `Folder` in the folders' array order, then Ungrouped. The rule is the single
/// definition the rail render and any future caller share — so "which folder is this in" means the
/// same thing everywhere. Mirrors how `ConnectionOrdering` keeps ordering in Domain.
public enum ConnectionGrouping {
    /// Bucket `connections` (kept in their global array order *within* each bucket — that order is
    /// the persisted reorder result) against `folders` (in their array order). Favorites is included
    /// only when non-empty; every folder gets a section even when empty (it's a drop target);
    /// Ungrouped is included only when non-empty. A connection is favorite-listed *and* still shown
    /// in its folder/ungrouped section (a favorite is a pin, not a move). A `folderId` that matches
    /// no folder reads as ungrouped, so a dangling reference never hides a connection.
    public static func sections(connections: [Connection], folders: [Folder]) -> [ConnectionSection] {
        let folderIDs = Set(folders.map(\.id))
        var sections: [ConnectionSection] = []

        let favorites = connections.filter(\.isFavorite)
        if !favorites.isEmpty {
            sections.append(ConnectionSection(kind: .favorites, connections: favorites))
        }

        for folder in folders {
            let members = connections.filter { $0.folderId == folder.id }
            sections.append(ConnectionSection(kind: .folder(folder), connections: members))
        }

        let ungrouped = connections.filter { $0.folderId == nil || !folderIDs.contains($0.folderId!) }
        if !ungrouped.isEmpty {
            sections.append(ConnectionSection(kind: .ungrouped, connections: ungrouped))
        }

        return sections
    }
}
