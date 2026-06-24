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

    /// The label a user-entered rename should commit, or `nil` to keep the current label.
    /// Empty/whitespace input is ignored (keep the old name). Unlike `resolved`, an
    /// unchanged-but-non-empty draft still commits — the operator opted in by editing, so a
    /// deliberate rename always locks the tab even when the text didn't change (#30).
    public static func renamed(to draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
