import Foundation

public enum TerminalBellPolicy {
    /// Whether a tab that just rang the bell (or posted a desktop notification) should raise an
    /// activity badge, or `false` to leave the strip untouched. Only an *inactive* tab flags: the
    /// active tab's surface is already on screen, so a badge there would only be visible while the
    /// app is backgrounded and would have to vanish the moment it returns — zero benefit, and
    /// gating it on `!isActiveTab` here means the dock needs no window-key observer. `enabled`
    /// mirrors the user's "show activity badge on background tabs" setting. Pure — one rule shared
    /// by every surface's bell callback (#74).
    public static func shouldFlag(isActiveTab: Bool, enabled: Bool) -> Bool {
        enabled && !isActiveTab
    }
}
