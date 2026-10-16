import Foundation

/// An optional per-connection color from a small named palette (#102), so a prod box and a dev box
/// read differently at a glance everywhere the connection appears. Only the *name* lives here: each
/// App-layer theme maps it to its own readable shade. The raw values are stable storage keys — they are
/// written to `connections.json` and synced over iCloud — so never rename a case; add new ones instead.
/// `Connection`'s decoder maps a key this build doesn't know to `nil`, so a store written by a newer
/// build still loads.
public enum ConnectionColor: String, CaseIterable, Sendable, Codable {
    case red, orange, yellow, green, teal, blue, purple, gray
}

/// Every place a connection's color is painted. Each surface gets its own strength from
/// `ConnectionColorPolicy`, so the rail, the tabs, the Mission Control tiles and the terminal itself
/// stay consistent with each other instead of each view picking a number.
public enum ConnectionColorSurface: Sendable, CaseIterable {
    /// The tinted background of the connection's rail row.
    case railRow
    /// The tinted background of an inactive terminal tab the connection opened.
    case tab
    /// The tinted header bar of the connection's Mission Control tile.
    case tileHeader
    /// The colored 1pt border of the connection's Mission Control tile.
    case tileBorder
    /// The faint tint blended into the terminal surface's own background.
    case terminalBackground
}

/// The tint rule: how strongly a connection's color is laid over each surface. Pure, so all four
/// surfaces share one definition and the readability bounds are unit-tested.
///
/// - No color means no tint at all (`0`), so an uncolored connection renders exactly as before.
/// - Fills stay faint (≤ 0.2) so text over them keeps its contrast; only the 1pt tile border is strong.
/// - The terminal background is the faintest fill: it sits under every line of output.
/// - A light theme gets lighter tints, since a saturated color reads stronger on white than on black.
public enum ConnectionColorPolicy {
    public static func opacity(of color: ConnectionColor?, on surface: ConnectionColorSurface,
                               lightTheme: Bool) -> Double {
        guard color != nil else { return 0 }
        switch surface {
        case .railRow: return lightTheme ? 0.08 : 0.12
        case .tab: return lightTheme ? 0.10 : 0.16
        case .tileHeader: return lightTheme ? 0.12 : 0.20
        case .tileBorder: return lightTheme ? 0.45 : 0.60
        case .terminalBackground: return lightTheme ? 0.04 : 0.07
        }
    }
}
