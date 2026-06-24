import Foundation

/// How repos within an org are ordered in the panel — the user's curated choice, persisted in
/// `Preferences.repoOrdering`. The raw values are stable storage keys, *not* display labels (so a
/// label change never invalidates a stored value); the App layer maps them to UI text. Mirrors the
/// storage/display split of `Preferences.groupBy`.
public enum RepoOrderingMode: String, Sendable, Codable, CaseIterable {
    case byName
    case byOpenCount

    /// The ordering used until the user picks one — alphabetical, the least surprising default.
    public static let `default`: RepoOrderingMode = .byName
}

/// Pure rule for the order repos take in the panel. Keeping the branching here — not in the view —
/// means the panel render and any future caller share one definition of "what order", just like
/// `OrgFollowing` does for the org list. The function works on `(name, open)` projections so Domain
/// needn't know the App's presentation `Repo` type; the caller reassembles, exactly as
/// `OrgFollowing.visible` returns ids the App maps back.
public enum RepoOrdering {
    /// Order `repos` by `mode`: case-insensitive name ascending, or open-count descending with a
    /// case-insensitive name tiebreak. The tiebreak makes `byOpenCount` deterministic even though
    /// `sorted` is not guaranteed stable; `byName` is already a total order.
    public static func order<T>(_ repos: [T], by mode: RepoOrderingMode,
                                name: (T) -> String, open: (T) -> Int) -> [T] {
        switch mode {
        case .byName:
            return repos.sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
        case .byOpenCount:
            return repos.sorted {
                open($0) != open($1)
                    ? open($0) > open($1)
                    : name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
        }
    }
}
