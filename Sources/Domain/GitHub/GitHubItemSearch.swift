import Foundation

/// Pure rule for the live free-text search over the issue/PR list. Keeping the matching here — not
/// in the view — means the list and any future caller share one definition of "does this item
/// match", just like `ConnectionSearch` does for the rail. The function takes plain values (the
/// fields the list searches: an item's title, its number, and its labels) so Domain needn't know
/// the App's presentation `Item` type.
public enum GitHubItemSearch {
    /// Whether `query` matches the item's title, number, or any label as a case- and
    /// diacritic-insensitive substring. The number is searched as `#<n>`, so both `76` and `#76`
    /// match item 76. An empty or whitespace-only query is the unfiltered list, so it matches
    /// everything.
    public static func matches(query: String, title: String, number: Int, labels: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let fields = [title, "#\(number)"] + labels
        return fields.contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
