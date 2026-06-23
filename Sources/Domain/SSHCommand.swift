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
    public static func command(host: String, port: Int, user: String?, custom: String? = nil) -> String {
        var parts = ["ssh"]
        if port != 22 { parts.append("-p \(port)") }
        let trimmedUser = user?.trimmingCharacters(in: .whitespaces) ?? ""
        parts.append(trimmedUser.isEmpty ? host : "\(trimmedUser)@\(host)")
        var line = parts.joined(separator: " ")
        if let custom = custom?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let escaped = custom.replacingOccurrences(of: "'", with: "'\\''")
            line += " -t '\(escaped)'"
        }
        return line
    }
}
