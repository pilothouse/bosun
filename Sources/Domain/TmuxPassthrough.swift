import Foundation

/// Pure rule for getting a terminal escape sequence *through* tmux to the outer terminal.
///
/// tmux is itself a terminal parser: an OSC/DCS emitted by a program inside a pane is consumed by
/// tmux and never reaches the host (ghostty), so Bosun's busy spinner — driven by OSC 9;4 — stays
/// dark on a tmux tab (#96). tmux's escape-hatch is *passthrough*: with `set -g allow-passthrough on`,
/// tmux forwards the payload of a `DCS tmux ; … ST` sequence verbatim, after stripping the envelope
/// and un-doubling ESCs. So to reach ghostty from inside tmux we wrap our OSC 9;4 in that envelope.
///
/// This is the single source of truth for the wrapping. The local zsh shim (`BusyShellIntegration`)
/// mirrors `wrap` in zsh; the SSH remote emitter reuses the shim body. Keep the mirror in lockstep
/// with the tests.
public enum TmuxPassthrough {
    /// The tmux option that must be on for `wrap`ped sequences to be forwarded to the host terminal.
    /// A bare tmux command (`tmux set …` prepends the binary); this is just the option itself.
    public static let allowPassthroughCommand = "set -g allow-passthrough on"

    private static let esc = "\u{1b}"

    /// Wrap a raw escape sequence in tmux's DCS passthrough envelope: double every ESC in the
    /// payload, then bracket it with `ESC P tmux ;` … `ESC \`. tmux (with `allow-passthrough on`)
    /// unwraps this and emits the original bytes to the host, so e.g. an OSC 9;4 progress report
    /// reaches ghostty and lights the tab spinner.
    public static func wrap(_ sequence: String) -> String {
        let doubled = sequence.replacingOccurrences(of: esc, with: esc + esc)
        return "\(esc)Ptmux;\(doubled)\(esc)\\"
    }
}
