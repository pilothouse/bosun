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

/// The busy state a signal reduces to, with enough detail for the view to pick its indicator: an
/// indeterminate spinner vs. a determinate progress ring (#94). `determinate` carries a clamped
/// 0–99 percentage; 100% (done) and every stop signal collapse to `idle`.
public enum TerminalBusyState: Equatable {
    case idle
    case indeterminate
    case determinate(Int)
}

public enum TerminalBusyPolicy {
    /// The busy state after this signal. Pure — one rule shared by every surface's activity
    /// callback. Busy starts on an in-flight progress report (INDETERMINATE → `.indeterminate`, or
    /// SET below 100% → `.determinate`) and stops on completion (SET 100%, REMOVE, ERROR, PAUSE) or
    /// a finished shell command (→ `.idle`). See `TerminalBusyPolicyTests` for the contract.
    public static func state(_ signal: TerminalBusySignal) -> TerminalBusyState {
        switch signal {
        case .progress(.indeterminate):
            return .indeterminate
        case .progress(.set(let percent)):
            // -1 means "no percentage given"; clamp so the ring is never negative. 100% is done.
            return percent < 100 ? .determinate(max(0, percent)) : .idle
        case .progress(.remove), .progress(.error), .progress(.pause), .commandFinished:
            return .idle
        }
    }

    /// Whether the tab is "busy" (show an indicator) after this signal — a thin wrapper over
    /// `state` so the two can't drift (the `TerminalBusyPolicyTests` pin this).
    public static func isBusy(_ signal: TerminalBusySignal) -> Bool {
        state(signal) != .idle
    }
}
