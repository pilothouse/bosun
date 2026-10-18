import Foundation

public enum TerminalDonePolicy {
    /// Whether a session is "done" — it finished work the user hasn't looked at yet (#103) — after one
    /// busy signal. Pure reducer over the previous value: starting work clears it; finishing work
    /// sets it only when the busy indicator was actually on screen (`wasVisiblyBusy`, so a command
    /// shorter than the spinner debounce never flashes done), the session isn't focused (you watched
    /// it finish), and the stop isn't the silent-tab backstop (`timedOut` — that means "no signal for
    /// a while", not "finished"). Any other signal keeps the previous value. The view clears it on
    /// focus, like the bell badge (`TerminalBellPolicy`).
    public static func next(isDone: Bool, wasVisiblyBusy: Bool, isBusy: Bool,
                            isFocused: Bool, timedOut: Bool) -> Bool {
        if isBusy { return false }
        if wasVisiblyBusy && !isFocused && !timedOut { return true }
        return isDone
    }
}
