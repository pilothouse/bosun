import Foundation

/// The state of an OSC 9;4 progress report (libghostty `GHOSTTY_PROGRESS_STATE_*`), modelled in
/// Domain so the busy rule stays free of C types. `set` carries a 0–100 percentage.
public enum ProgressState: Equatable {
    case remove
    case set(Int)
    case error
    case indeterminate
    case pause
}

/// One activity signal libghostty can hand us for a surface (#93). `progress` is OSC 9;4;
/// `commandFinished` is the shell-integration (OSC 133) command-end. There is deliberately no
/// `commandStarted` case — libghostty exposes no such action — so the spinner is *started* only by
/// an explicit progress report and *stopped* by either a progress report or a finished command.
public enum TerminalBusySignal: Equatable {
    case progress(ProgressState)
    case commandFinished
}

public enum TerminalBusyPolicy {
    /// Whether the tab is "busy" (show the spinner) after this signal. Pure — one rule shared by
    /// every surface's activity callback. Busy starts on an in-flight progress report
    /// (INDETERMINATE, or SET below 100%) and stops on completion (SET 100%, REMOVE, ERROR, PAUSE)
    /// or a finished shell command. See `TerminalBusyPolicyTests` for the contract.
    public static func isBusy(_ signal: TerminalBusySignal) -> Bool {
        switch signal {
        case .progress(.indeterminate):
            return true
        case .progress(.set(let percent)):
            return percent < 100
        case .progress(.remove), .progress(.error), .progress(.pause):
            return false
        case .commandFinished:
            return false
        }
    }
}
