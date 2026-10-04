import Foundation

/// Mission Control's two views. Raw values are stable storage keys (`Preferences.missionMode`).
/// `grid` shows one page of live tiles; `focus` shows one large live tile beside a list of the rest.
public enum MissionView: String, Sendable, Codable, CaseIterable {
    case grid, focus

    public static let `default`: MissionView = .grid

    /// The view for a stored key. Unknown keys (including the retired v1/v2 mode names) map to grid.
    public static func stored(_ raw: String?) -> MissionView {
        raw.flatMap(MissionView.init(rawValue:)) ?? .default
    }

    /// The view for a 1-based shortcut digit (⌃⌘1 grid, ⌃⌘2 focus), or nil.
    public static func forShortcut(_ digit: Int) -> MissionView? {
        guard digit >= 1, digit <= allCases.count else { return nil }
        return allCases[digit - 1]
    }
}

/// The grid shape the user picks — literally the columns × rows on screen, so what you pick is what
/// you see. `auto` resolves to the smallest fixed preset that fits every session at a usable size
/// (`MissionPagePolicy.shape`). Raw values are stable storage keys (`Preferences.missionLayout`).
public enum MissionLayoutPreset: String, Sendable, Codable, CaseIterable {
    case auto
    case one = "1x1"
    case oneByTwo = "1x2"
    case two = "2x1"
    case twoByTwo = "2x2"
    case threeByTwo = "3x2"
    case threeByThree = "3x3"

    public static let `default`: MissionLayoutPreset = .auto

    /// The fixed presets, fewest tiles first (1×2 stacked before 2×1 side by side).
    public static let fixed: [MissionLayoutPreset] = [.one, .oneByTwo, .two, .twoByTwo, .threeByTwo, .threeByThree]

    public static func stored(_ raw: String?) -> MissionLayoutPreset {
        raw.flatMap(MissionLayoutPreset.init(rawValue:)) ?? .default
    }

    /// Columns × rows of a fixed preset; nil for `auto` (it has no shape until resolved).
    public var shape: (columns: Int, rows: Int)? {
        switch self {
        case .auto: return nil
        case .one: return (1, 1)
        case .oneByTwo: return (1, 2)
        case .two: return (2, 1)
        case .twoByTwo: return (2, 2)
        case .threeByTwo: return (3, 2)
        case .threeByThree: return (3, 3)
        }
    }
}

/// How the issue/PR tracker is shown: hidden, a list on the right, or a board along the bottom.
/// Raw values are stable storage keys (`Preferences.missionTracker`).
public enum MissionTrackerStyle: String, Sendable, Codable, CaseIterable {
    case off, list, board

    public static let `default`: MissionTrackerStyle = .list

    public static func stored(_ raw: String?) -> MissionTrackerStyle {
        raw.flatMap(MissionTrackerStyle.init(rawValue:)) ?? .default
    }

    /// The style the ⌃⌘T toggle switches to: off ↔ the last visible style (list when unknown).
    public func toggled(lastVisible: MissionTrackerStyle) -> MissionTrackerStyle {
        self == .off ? (lastVisible == .off ? .list : lastVisible) : .off
    }
}

/// Which tiles Mission Control shows by activity. Session-only (not persisted).
public enum MissionFilter: String, Sendable, CaseIterable {
    case all, working, attention
}
