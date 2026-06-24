import Foundation

public enum TerminalTitlePolicy {
    /// The label a server/OSC-reported title should produce for a tab, or `nil` to keep the
    /// current label. Locked tabs (a named connection; a user-renamed tab once #30 lands) ignore
    /// server titles so the operator's chosen name survives. An empty/whitespace or unchanged
    /// incoming title is ignored either way. Pure — one rule shared by every surface's title
    /// callback.
    public static func resolved(incoming: String, current: String, locked: Bool) -> String? {
        guard !locked else { return nil }
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }
}
