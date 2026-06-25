import Foundation

/// The app-wide zoom level — a pure rule, like `SplitLayout`, so the menu actions, the launch
/// restore, and any test share one definition of "how big is the UI right now". The level is a
/// whole **percent** on a fixed 10% grid in `[50, 200]` (an `Int`, so it never drifts the way a
/// repeatedly-stepped `Double` would), persisted in `Preferences.uiZoomPercent`. The App layer
/// reads `scale` and multiplies it into both the UI fonts/geometry and the terminal's font size, so
/// one zoom moves everything in lockstep. Stays in `Double`/`Int` so Domain keeps free of
/// CoreGraphics; the App layer converts at the boundary.
public struct UIZoom: Equatable, Sendable, Codable {
    /// Smallest readable zoom (50%) and largest useful one (200%) — the divider stops here rather
    /// than letting the UI shrink to nothing or balloon past the window, mirroring `SplitLayout`'s
    /// `minPane` clamp.
    public static let minPercent = 50
    public static let maxPercent = 200
    /// The grid the in/out steps move on (10%), also used to snap a stray restored value.
    public static let step = 10

    /// The current level as a whole percent, always clamped to `[minPercent, maxPercent]` and
    /// snapped to the `step` grid.
    public let percent: Int

    /// The multiplier the App layer applies to fonts, layout constants, and the terminal font size.
    public var scale: Double { Double(percent) / 100 }

    public init(percent: Int = 100) {
        let snapped = Int((Double(percent) / Double(Self.step)).rounded()) * Self.step
        self.percent = min(Self.maxPercent, max(Self.minPercent, snapped))
    }

    /// The level used until the user zooms — 1:1, so an upgrade looks unchanged.
    public static let `default` = UIZoom()

    /// One step larger, clamped at `maxPercent`.
    public func zoomedIn() -> UIZoom { UIZoom(percent: percent + Self.step) }

    /// One step smaller, clamped at `minPercent`.
    public func zoomedOut() -> UIZoom { UIZoom(percent: percent - Self.step) }

    /// Back to 1:1 — the ⌘0 "Actual Size" action.
    public func reset() -> UIZoom { UIZoom() }

    /// Decode through the clamping initializer so a stored (or corrupt) value can never seat an
    /// out-of-range or off-grid level — the same tolerance `Preferences` applies to its fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(percent: try container.decode(Int.self))
    }

    /// Encode as the bare percent (not a wrapping object), the same shape `Preferences` persists.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percent)
    }
}
