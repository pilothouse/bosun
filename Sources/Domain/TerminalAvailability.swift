import Foundation

/// The point in libghostty bring-up at which the terminal subsystem failed to come up.
/// Mirrors the three fallible steps the App layer drives, from earliest to latest.
public enum TerminalStartupStage: Sendable, Equatable, CaseIterable {
    case runtimeInit      // ghostty_init     — global runtime init
    case configuration    // ghostty_config_new
    case application      // ghostty_app_new
}

/// Whether the terminal subsystem is usable. A pure fact the App layer reads to decide between
/// rendering the live surface and rendering an error state — the same outcome whether bring-up
/// is driven from the menu bar, a test, or a future headless path. Carries the failing stage so
/// callers can explain *what* failed; the user-facing wording itself stays in the App layer.
public enum TerminalAvailability: Sendable, Equatable {
    case ready
    case unavailable(TerminalStartupStage)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
