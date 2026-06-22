import Foundation

public enum SSHCommand {
    /// The shell command line that opens an interactive SSH session for a connection:
    /// `ssh [-p PORT] [user@]host`. The port flag is omitted at the default (22), and the
    /// `user@` prefix is dropped when no (non-blank) user is set. Pure — the same string is
    /// used whether the session is launched from a double-click, a menu, or a test.
    public static func command(host: String, port: Int, user: String?) -> String {
        var parts = ["ssh"]
        if port != 22 { parts.append("-p \(port)") }
        let trimmedUser = user?.trimmingCharacters(in: .whitespaces) ?? ""
        parts.append(trimmedUser.isEmpty ? host : "\(trimmedUser)@\(host)")
        return parts.joined(separator: " ")
    }
}
