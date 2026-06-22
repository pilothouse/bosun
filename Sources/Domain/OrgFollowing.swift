import Foundation

/// Pure rules for the orgs the user follows in the panel. The set of *available* orgs comes from
/// GitHub; which of them to show, and in what order, is the user's curated choice (persisted in
/// `Preferences.followedOrgs`). Keeping the branching here — not in the manage view — means the
/// panel render and the manage sheet share one definition of "what's visible", and the reorder
/// gesture and any future caller agree on what a move means.
public enum OrgFollowing {
    /// The orgs to display, in order. `followed == nil` means the user never customized the list,
    /// so every available org shows in its incoming order. Otherwise only the followed ids that
    /// still correspond to an available org show, in the saved order — stale ids (an org the
    /// viewer has since left) are dropped.
    public static func visible(available: [String], followed: [String]?) -> [String] {
        guard let followed else { return available }
        let valid = Set(available)
        return followed.filter(valid.contains)
    }

    /// Move the entry at `from` to `to`, returning the reordered list. Out-of-range indices or
    /// `from == to` leave the list unchanged.
    public static func reorder(_ ids: [String], from: Int, to: Int) -> [String] {
        guard ids.indices.contains(from), ids.indices.contains(to), from != to else { return ids }
        var result = ids
        let moved = result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }
}
