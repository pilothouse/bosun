import Foundation

/// Which top-level arrangement the main window shows — the user's choice, persisted in
/// `Preferences.workspaceLayout`. `classic` is the connection rail + detail/terminal column + repo
/// panel the app has always shipped; `missionControl` swaps all three for a grid of live terminal
/// tiles flanked by a repo rail and an issue/PR tracker. The raw values are stable storage keys,
/// not display labels. Mirrors `SplitAxis`.
public enum WorkspaceLayout: String, Sendable, Codable, CaseIterable {
    case classic, missionControl

    /// The layout used until the user picks one, so an upgrade looks unchanged.
    public static let `default`: WorkspaceLayout = .classic

    /// The other layout — what the menu toggle switches to.
    public var toggled: WorkspaceLayout { self == .classic ? .missionControl : .classic }
}
