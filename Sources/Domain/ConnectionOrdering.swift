import Foundation

/// Pure rules for the persisted order of saved connections. The rail shows connections in three
/// filtered sections (favorites / SSH remotes / local folders), and their order is simply the
/// array order of the stored list. A drag reorders one section's members among the slots they
/// already occupy in that list, leaving every other connection fixed — so the global order stays
/// a single source of truth and the move means the same thing wherever it's read. Mirrors
/// `OrgFollowing.reorder`, but section-aware: the reorder use case and the rail's optimistic
/// update share this one definition of what a move does.
public enum ConnectionOrdering {
    /// Move the entry at `from` to `to` *within* `sectionIDs` (a section's ids in display order),
    /// then splice the reordered section back over the slots its members hold in `allIDs`. Ids
    /// outside the section keep their absolute position. Out-of-range indices or `from == to`
    /// leave `allIDs` unchanged.
    ///
    /// `sectionIDs` is expected to be a subset of `allIDs` in the same relative order (that's how
    /// the rail derives a section by filtering), so the splice consumes exactly one reordered id
    /// per section slot; the `?? id` fallback only guards a malformed call.
    public static func reorder(_ allIDs: [UUID], sectionIDs: [UUID], from: Int, to: Int) -> [UUID] {
        guard sectionIDs.indices.contains(from), sectionIDs.indices.contains(to), from != to else { return allIDs }
        var section = sectionIDs
        section.insert(section.remove(at: from), at: to)
        let members = Set(sectionIDs)
        var next = section.makeIterator()
        return allIDs.map { members.contains($0) ? (next.next() ?? $0) : $0 }
    }

    /// `allIDs` with `id` sitting immediately after `anchor` — where a duplicated connection belongs,
    /// so the copy appears directly under the row it was made from (#101). Because the rail derives
    /// every section by filtering this one global list (`ConnectionGrouping.sections`), placing the
    /// copy here puts it under its original in *every* band that shows both — its folder and, for a
    /// favourited source, the pinned Favorites band too.
    ///
    /// An `id` already in the list is moved rather than repeated (the result is always a set), a
    /// missing `anchor` appends, and `id == anchor` is a no-op that still guarantees `id` is present.
    public static func inserting(_ id: UUID, after anchor: UUID, in allIDs: [UUID]) -> [UUID] {
        guard id != anchor else { return allIDs.contains(id) ? allIDs : allIDs + [id] }
        var ids = allIDs.filter { $0 != id }
        guard let anchorIndex = ids.firstIndex(of: anchor) else { return ids + [id] }
        ids.insert(id, at: ids.index(after: anchorIndex))
        return ids
    }
}
