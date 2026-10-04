import Foundation

/// Reordering Mission Control tiles by drag. A tile is one terminal pane, and panes belong to tabs;
/// the tile order *is* the tab order (each tab's panes stay together), so a drop moves the dragged
/// pane's whole tab into the target pane's tab slot. That keeps the classic tab strip in the same
/// order and reuses its persistence.
public enum MissionTileReorder {

    /// The tab move (`TerminalTabs.reorder(from:to:)` indices) for dropping a pane of `draggedTab` on
    /// a pane of `targetTab`, or nil when there's nothing to move (same tab, or a tab not in `tabOrder`).
    /// The dragged tab takes the target's slot: dropping later in the order lands after the target,
    /// dropping earlier lands before it.
    public static func tabMove<ID: Equatable>(tabOrder: [ID], draggedTab: ID, targetTab: ID) -> (from: Int, to: Int)? {
        guard draggedTab != targetTab,
              let from = tabOrder.firstIndex(of: draggedTab),
              let to = tabOrder.firstIndex(of: targetTab) else { return nil }
        return (from, to)
    }
}
