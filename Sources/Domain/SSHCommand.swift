import Foundation

public enum SSHCommand {
    /// The shell command line that opens an interactive SSH session for a connection:
    /// `ssh [-p PORT] [user@]host`. The port flag is omitted at the default (22), and the
    /// `user@` prefix is dropped when no (non-blank) user is set. Pure — the same string is
    /// used whether the session is launched from a double-click, a menu, or a test.
    ///
    /// A non-blank `custom` command is folded onto the end as `-t '<custom>'`, forcing a remote
    /// pty so interactive programs (e.g. `tmux new -n dev`) work. The command is wrapped in
    /// single quotes with POSIX `'\''` escaping so spaces and metacharacters survive both the
    /// local launch and ssh's own re-joining of the remote command.
    ///
    /// When `busyShim` is non-nil *and* `custom` launches tmux, the tmux command is rewritten to
    /// carry the busy-spinner integration into the remote session (#96): it enables tmux's
    /// `allow-passthrough` and installs the shim as a throwaway remote `ZDOTDIR`, so the remote
    /// shell emits OSC 9;4 (DCS-wrapped, via the shim) and tmux forwards it to ghostty. `busyShim`
    /// nil (the default) — or a non-tmux `custom` — leaves the command byte-for-byte unchanged.
    public static func command(host: String, port: Int, user: String?,
                               custom: String? = nil, busyShim: String? = nil) -> String {
        var parts = ["ssh"]
        if port != 22 { parts.append("-p \(port)") }
        let trimmedUser = user?.trimmingCharacters(in: .whitespaces) ?? ""
        parts.append(trimmedUser.isEmpty ? host : "\(trimmedUser)@\(host)")
        var line = parts.joined(separator: " ")
        guard let raw = custom?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return line }
        let remote = remoteCommand(custom: raw, busyShim: busyShim)
        let escaped = remote.replacingOccurrences(of: "'", with: "'\\''")
        line += " -t '\(escaped)'"
        return line
    }

    /// The command actually run on the remote host. Identity for a plain custom command; for a tmux
    /// launch with busy integration, the passthrough-enabled, shim-installing rewrite.
    private static func remoteCommand(custom: String, busyShim: String?) -> String {
        guard let shim = busyShim, isTmuxInvocation(custom) else { return custom }
        // Base64 keeps the shim (which contains quotes, `$`, ESCs) free of shell metacharacters, so
        // nothing here needs single quotes and the outer single-quote wrapping stays trivial.
        let encoded = Data(shim.utf8).base64EncodedString()
        return "export ZDOTDIR=\"$(mktemp -d)\"; "
            + "printf %s \(encoded) | openssl base64 -d -A > \"$ZDOTDIR/.zshenv\"; "
            + "exec \(passthroughEnabledTmux(custom))"
    }

    private static func isTmuxInvocation(_ custom: String) -> Bool {
        custom == "tmux" || custom.hasPrefix("tmux ")
    }

    /// Prepend tmux's own `set -g allow-passthrough on` to the user's tmux subcommand, chained with
    /// an escaped `\;` so it reaches tmux as a literal command separator. A bare `tmux` (no
    /// subcommand) becomes `new-session` so it still starts and attaches a session.
    private static func passthroughEnabledTmux(_ custom: String) -> String {
        let enable = "tmux \(TmuxPassthrough.allowPassthroughCommand) \\;"
        let rest = String(custom.dropFirst("tmux".count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? "\(enable) new-session" : "\(enable) \(rest)"
    }
}
