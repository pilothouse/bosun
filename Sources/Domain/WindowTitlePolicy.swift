import Foundation

public enum WindowTitlePolicy {
    /// The macOS window title for the current selection: the active console tab's label (#73), which
    /// already encodes what you're looking at — the connection name for a connection console (locked
    /// per `TerminalTitlePolicy`, so the server's OSC title can't overwrite it), or the shell/cwd
    /// title for a plain local tab. Trimmed; an empty/whitespace or absent console falls back to
    /// `fallback`. Pure — one rule for the App layer's title wiring.
    public static func title(console: String?, fallback: String = "Bosun") -> String {
        let trimmed = (console ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
