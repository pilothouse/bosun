import Foundation

/// The outline a Mission Control tile gets from its activity when "Highlight activity" is on (#103).
public enum MissionTileBorder: Sendable, Equatable {
    /// Whatever the tile shows today (its connection color, or the plain card border).
    case standard
    /// Work in progress — an accent outline that pulses.
    case working
    /// Finished while you looked elsewhere — a green outline.
    case done
}

/// How a tile is emphasized: its outline, and whether its terminal body is dimmed.
public struct MissionTileTreatment: Sendable, Equatable {
    public let border: MissionTileBorder
    public let dimmed: Bool

    public init(border: MissionTileBorder, dimmed: Bool) {
        self.border = border
        self.dimmed = dimmed
    }
}

/// The "Highlight activity" rule (#103): make every tile's state readable at a glance without hiding
/// any tile. Working and done tiles get an outline, quiet tiles dim, and "needs you" keeps its own
/// amber treatment. Off returns the plain treatment for everything, so the toggle is invisible.
public enum MissionHighlightPolicy {
    public static func treatment(activity: MissionTileActivity, focused: Bool, enabled: Bool) -> MissionTileTreatment {
        guard enabled else { return MissionTileTreatment(border: .standard, dimmed: false) }
        switch activity {
        case .working: return MissionTileTreatment(border: .working, dimmed: false)
        case .done: return MissionTileTreatment(border: .done, dimmed: false)
        case .attention: return MissionTileTreatment(border: .standard, dimmed: false)
        // The focused tile is where you type; dimming it would hide your own work.
        case .idle: return MissionTileTreatment(border: .standard, dimmed: !focused)
        }
    }
}
