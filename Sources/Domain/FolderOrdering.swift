import Foundation

/// Pure rule for the persisted order of user folders. Folders render in the rail in their stored
/// array order (the `ConnectionOrdering` precedent — a stored list *is* the display order), so a
/// drag reorders that one flat list. Mirrors `OrgFollowing.reorder`, typed to `Folder.id`, so the
/// reorder use case and any optimistic UI update share one definition of what a move means.
public enum FolderOrdering {
    /// Move the entry at `from` to `to`, returning the reordered ids. Out-of-range indices or
    /// `from == to` leave the list unchanged.
    public static func reorder(_ ids: [UUID], from: Int, to: Int) -> [UUID] {
        guard ids.indices.contains(from), ids.indices.contains(to), from != to else { return ids }
        var result = ids
        result.insert(result.remove(at: from), at: to)
        return result
    }
}
