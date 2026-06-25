import Foundation

/// Pure rule for which repos the org panel shows. Keeping the branching here — not in the view —
/// means the panel render, the org repo-count badge, and the auto-select in `GitHubDataController`
/// share one definition of "visible", just like `RepoOrdering` does for the order. The function
/// works on an `open` projection so Domain needn't know the App's presentation `Repo` type; the
/// caller reassembles, exactly as `RepoOrdering.order` returns items the App maps back.
public enum RepoVisibility {
    /// Repos to show. `skipEmpty` off → every repo, untouched. On → drop repos whose open issue+PR
    /// count is zero. "Empty" is always *open*-only: the caller passes the open count, so the rule
    /// keeps meaning zero open items even if closed/merged totals are added to the projection later.
    public static func visible<T>(_ repos: [T], skipEmpty: Bool, open: (T) -> Int) -> [T] {
        skipEmpty ? repos.filter { open($0) > 0 } : repos
    }
}
