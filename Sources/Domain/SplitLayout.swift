import Foundation

/// Pure sizing rule for the horizontal detail/terminal split. Keeping the clamping here — not in
/// the view or store — means the divider drag and the layout pass share one definition of "how
/// small a pane may get", just like `ItemSorting` owns "what order". The terminal's share is a
/// *fraction* of the center column's width (not a pixel value): that column swings wide as the
/// sidebar and orgs panel collapse, and a fraction keeps the split looking right across those
/// changes. Works in `Double` so Domain stays free of CoreGraphics; the App layer converts at the
/// boundary. The vertical split keeps its pixel height and doesn't use this.
public enum SplitLayout {
    /// The smallest width either pane may be dragged to (points). Below this a pane is unusable, so
    /// the divider stops here rather than letting one side swallow the other.
    public static let minPane: Double = 220

    /// The terminal's share of the width the first time the user switches to a horizontal split.
    public static let defaultFraction: Double = 0.45

    /// Clamp a terminal-width `fraction` so both panes keep at least `minPane` points. When the
    /// container is too narrow to honor that on both sides, fall back to an even split rather than
    /// pinning one pane shut. A non-positive `total` (the view isn't laid out yet) passes through
    /// unharmed — there's no geometry to clamp against.
    public static func clampFraction(_ fraction: Double, total: Double, minPane: Double = minPane) -> Double {
        guard total > 0 else { return fraction }
        let lo = minPane / total
        let hi = 1 - minPane / total
        guard lo <= hi else { return 0.5 }
        return min(max(fraction, lo), hi)
    }

    /// The terminal's pixel extent along the split for a (clamped) `fraction` of `total`.
    public static func terminalExtent(total: Double, fraction: Double, minPane: Double = minPane) -> Double {
        total * clampFraction(fraction, total: total, minPane: minPane)
    }

    /// Sign that turns a divider drag — a signed move along the split axis, in window space (y up,
    /// x right) — into a change in the terminal's size. `+1` means a positive move grows the
    /// terminal, `-1` shrinks it. The sign flips with `terminalLeading` because the grip moves to
    /// the terminal's opposite edge: with the terminal trailing (bottom/right, the default) the
    /// grip is on its top/left edge, so dragging up/left grows it; with the terminal leading
    /// (top/left) the grip is on its bottom/right edge, so the same gesture shrinks it.
    public static func dragGrowsTerminal(axis: SplitAxis, terminalLeading: Bool) -> Double {
        switch axis {
        case .vertical:   return terminalLeading ? -1 : 1
        case .horizontal: return terminalLeading ? 1 : -1
        }
    }
}
