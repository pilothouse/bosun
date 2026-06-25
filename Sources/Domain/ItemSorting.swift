import Foundation

/// How the issue/PR list is sorted — the user's choice, persisted in `Preferences.sortField`. The
/// raw values are stable storage keys, *not* display labels (so a label change never invalidates a
/// stored value); the App layer maps them to UI glyphs. Mirrors the storage/display split of
/// `Preferences.groupBy` and `RepoOrderingMode`.
public enum ItemSortField: String, Sendable, Codable, CaseIterable {
    case date, number, title

    /// The field used until the user picks one — newest-first by date, the least surprising default.
    public static let `default`: ItemSortField = .date
}

/// Pure rule for the order issues/PRs take in the panel. Keeping the branching here — not in the
/// view or store — means the flat list and the grouped tree's siblings share one definition of
/// "what order", just like `RepoOrdering` does for the repo list. The function works on
/// `(date, number, title)` projections so Domain needn't know the App's presentation `Item` type;
/// the caller passes key paths, exactly as `RepoOrdering.order` does.
public enum ItemSorting {
    /// Order `items` by `field`. Title compares case-insensitively; date and number use their natural
    /// orderings. Every field breaks ties on `number` so the result is deterministic even though
    /// `sorted` isn't guaranteed stable. `ascending` reverses the natural ascending order.
    public static func sort<T>(_ items: [T], by field: ItemSortField, ascending: Bool,
                               date: (T) -> Date, number: (T) -> Int, title: (T) -> String) -> [T] {
        let asc: [T]
        switch field {
        case .date:
            asc = items.sorted {
                date($0) != date($1) ? date($0) < date($1) : number($0) < number($1)
            }
        case .number:
            asc = items.sorted { number($0) < number($1) }
        case .title:
            asc = items.sorted {
                let cmp = title($0).localizedCaseInsensitiveCompare(title($1))
                return cmp != .orderedSame ? cmp == .orderedAscending : number($0) < number($1)
            }
        }
        return ascending ? asc : asc.reversed()
    }
}
