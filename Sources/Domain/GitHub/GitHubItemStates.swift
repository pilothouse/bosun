import Foundation

/// Pure rules for the multi-status list filter — which lifecycle states a fetch should request,
/// whether that fetch must bound its closed/merged history, and how a state maps onto the GraphQL
/// enum token the query expects. The user's selection (persisted per tab) is a `Set` of states;
/// keeping the branching here — not in the adapter or the panel — means the query builder, the
/// display filter, and any future caller agree on what "open issues and closed PRs" actually means.
public enum GitHubItemStates {
    /// How many newest closed/merged items a bounded fetch keeps before stopping. Open-only stays
    /// unbounded (it's the active working set, typically small); closed history can run to
    /// thousands, so a broader selection caps it and the caller surfaces the cap.
    public static let historyCap = 200

    /// The states to actually request for a kind, given the user's selection. An empty selection
    /// falls back to `[.open]` so a fetch never asks for nothing. Issues have no `merged` state, so
    /// it's dropped there; if dropping it would leave the set empty (a `merged`-only issue
    /// selection, which the UI never offers but we guard anyway), fall back to `[.open]`.
    public static func requested(for kind: GitHubItemKind,
                                 selected: Set<GitHubItemState>) -> Set<GitHubItemState> {
        let base = selected.isEmpty ? [.open] : selected
        guard kind == .issue else { return base }
        let valid = base.subtracting([.merged])
        return valid.isEmpty ? [.open] : valid
    }

    /// Whether a fetch for these states must bound its history. Only the open-only fast path is
    /// unbounded; any broader selection reaches into closed/merged history and is capped.
    public static func bounded(_ states: Set<GitHubItemState>) -> Bool {
        states != [.open]
    }

    /// The GraphQL enum token GitHub's `IssueState`/`PullRequestState` filters expect.
    public static func graphQLToken(_ state: GitHubItemState) -> String {
        switch state {
        case .open: "OPEN"
        case .closed: "CLOSED"
        case .merged: "MERGED"
        }
    }
}
