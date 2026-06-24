import Foundation

/// Pure rule for the live "Search connections" filter in the rail. Keeping the matching here — not
/// in the view — means the rail and any future caller share one definition of "does this connection
/// match", just like `RepoOrdering` does for repo order. The function takes plain strings (the
/// fields the rail shows: a connection's name and its meta) so Domain needn't know the App's
/// presentation `Connection` type.
public enum ConnectionSearch {
    /// Whether `query` matches any of `fields` as a case- and diacritic-insensitive substring.
    /// An empty or whitespace-only query is the unfiltered list, so it matches everything.
    public static func matches(query: String, in fields: String...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return fields.contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
