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
}
