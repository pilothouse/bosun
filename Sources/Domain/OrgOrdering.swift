import Foundation

/// How the organization list is ordered in the panel — the user's choice, persisted in
/// `Preferences.orgOrdering`. The raw values are stable storage keys, *not* display labels (so a
/// label change never invalidates a stored value); the App layer maps them to UI text. Mirrors the
/// storage/display split of `RepoOrderingMode` and `ItemSortField`. `.manual` is the curated drag
/// order from `OrgFollowing`; `.byName`/`.byActivity` honor a direction (see `OrgOrdering`).
public enum OrgOrderingMode: String, Sendable, Codable, CaseIterable {
    case manual
    case byName
    case byActivity

    /// The ordering used until the user picks one — the manual drag order, so an upgrade leaves the
    /// list exactly as the user arranged it.
    public static let `default`: OrgOrderingMode = .manual
}

/// Pure rule for the order organizations take in the panel — the org-level analogue of
/// `RepoOrdering`. Keeping the branching here, not in the view or store, means the sidebar render
/// and the Manage sheet share one definition of "what order". The function works on
/// `(name, activity)` projections so Domain needn't know the App's presentation `Org` type; the
/// caller passes key paths, exactly as `RepoOrdering.order` and `ItemSorting.sort` do.
public enum OrgOrdering {
    /// Order `orgs` by `mode`. `.manual` returns the input unchanged — it *is* the user's drag order
    /// (`OrgFollowing`), and direction doesn't apply. `.byName` compares case-insensitively;
    /// `.byActivity` (total open issues+PRs across the org's repos, the org-level parallel of
    /// `RepoOrderingMode.byOpenCount`) breaks ties on case-insensitive name so the ascending build is
    /// deterministic even though `sorted` isn't guaranteed stable. `ascending` reverses the natural
    /// ascending order for the two sorted modes, exactly as `ItemSorting.sort` does.
    public static func order<T>(_ orgs: [T], by mode: OrgOrderingMode, ascending: Bool,
                                name: (T) -> String, activity: (T) -> Int) -> [T] {
        switch mode {
        case .manual:
            return orgs
        case .byName:
            let asc = orgs.sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
            return ascending ? asc : asc.reversed()
        case .byActivity:
            let asc = orgs.sorted {
                activity($0) != activity($1)
                    ? activity($0) < activity($1)
                    : name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
            return ascending ? asc : asc.reversed()
        }
    }
}
