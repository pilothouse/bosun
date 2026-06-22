import Foundation

public enum TerminalClosePolicy {
    /// Whether closing a terminal surface needs user confirmation. A surface whose child
    /// process has already exited can close silently; one with a live process should confirm
    /// so running work isn't lost. Pure — one rule shared by every close path (the window
    /// close today, a tab close once #10 lands).
    public static func shouldConfirmClose(processAlive: Bool) -> Bool {
        processAlive
    }
}
