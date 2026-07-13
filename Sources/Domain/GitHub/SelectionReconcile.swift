/// The *selection-follows-tab* rule behind issue #100. When a scope's PR/issue lists (re)load, the
/// open item should stay visible — if it lives on the other tab, reveal that tab. But that switch is
/// only ever right when **establishing** a freshly-opened scope (cold open / restore / an explicit
/// repo-or-org selection); a background or live-delta *refresh* must never move the tab out from
/// under the user (they may have deliberately switched tabs while an item from the other tab is still
/// selected). This is the "if" Domain owns, so the reveal decision lives in one deterministic,
/// unit-tested place instead of the App-layer reconcile.
///
/// The fallback-selection logic (pick a valid item when the open one is gone) stays in the caller —
/// it reads the store's already-sorted/filtered lists directly; only the buggy tab-switch is
/// extracted here.
public enum SelectionReconcile {
    public enum Tab: Equatable { case prs, issues }

    /// Which tab should be switched to so the open item is visible, or `nil` to keep the current tab.
    /// - Parameters:
    ///   - selectedId: the currently-open item's id (`""` when nothing is selected).
    ///   - currentTabHasSelected: whether the current tab's visible list already contains it.
    ///   - selectedIsPR / selectedIsIssue: whether the id is present in the PRs / issues list.
    ///   - establishing: `true` only on a scope's first population (open/restore/explicit select);
    ///     `false` on every subsequent data refresh.
    public static func revealTab(selectedId: String,
                                 currentTabHasSelected: Bool,
                                 selectedIsPR: Bool,
                                 selectedIsIssue: Bool,
                                 establishing: Bool) -> Tab? {
        guard establishing, !selectedId.isEmpty, !currentTabHasSelected else { return nil }
        if selectedIsPR { return .prs }
        if selectedIsIssue { return .issues }
        return nil
    }
}
