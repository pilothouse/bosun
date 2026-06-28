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

    /// The smallest the terminal may be dragged to in a *vertical* (stacked) split (points). Stacked
    /// panes are bounded by rows of text, not column width, so this stays far below `minPane` (the
    /// side-by-side *width* floor) and preserves the long-standing 120pt terminal floor.
    public static let minTerminalHeight: Double = 120

    /// The smallest the detail pane may be squeezed to in a vertical split (points). The detail pane
    /// previously had no floor and could be crushed toward zero on short windows (#65).
    public static let minDetailHeight: Double = 120

    /// The smallest the Organizations region may be dragged to in the repo panel's orgs/issues
    /// split (points) — roughly two org rows, so the divider can never collapse it to nothing.
    /// The orgs/issues split is a *vertical* (stacked) split, so it reuses `clampExtent` with this
    /// as the top-pane floor; the bottom pane's floor (the fixed header/tabs/search/controls chrome
    /// plus a few list rows) is App-layer geometry passed in as `minDetail` (#91).
    public static let minOrgsListHeight: Double = 96

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

    /// Clamp an absolute terminal `extent` (points, along a vertical split) so the terminal keeps at
    /// least `minTerminal` and the detail pane keeps at least `minDetail`. This is the pixel twin of
    /// `clampFraction`: the vertical split stores a height in points, so its bound is absolute and
    /// container-relative (the ceiling is `total - minDetail`) rather than a fixed pixel value — that
    /// way a large display isn't capped and the detail pane can't be crushed to zero (#65). When the
    /// container is too short to honor both floors, fall back to an even split rather than pinning one
    /// pane shut. A non-positive `total` (the view isn't laid out yet) passes through unharmed.
    public static func clampExtent(_ extent: Double, total: Double,
                                   minTerminal: Double = minTerminalHeight,
                                   minDetail: Double = minDetailHeight) -> Double {
        guard total > 0 else { return extent }
        let lo = minTerminal
        let hi = total - minDetail
        guard lo <= hi else { return total / 2 }
        return min(max(extent, lo), hi)
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

    /// The seam's coordinate along the split axis (points from the leading edge), where the divider
    /// grip is centered. The terminal occupies the leading edge when `terminalLeading`, so the seam
    /// is at its far edge; otherwise the terminal is trailing and the seam sits one terminal-extent
    /// in from the trailing edge. The view straddles this line with a fat hit-zone so the resize
    /// target is centered on the seam rather than carved off one pane (#84). The `extent` is the
    /// terminal's already-clamped size along the axis (`clampExtent` / `terminalExtent`).
    public static func seamPosition(total: Double, terminalExtent: Double, terminalLeading: Bool) -> Double {
        terminalLeading ? terminalExtent : total - terminalExtent
    }
}
