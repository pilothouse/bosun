import Foundation

/// A GitHub account that authored something — an item or a comment. Just identity and avatar;
/// the presentation layer derives initials and colors from the login.
public struct GitHubActor: Sendable, Equatable, Codable {
    public let login: String
    public let avatarURL: URL?

    public init(login: String, avatarURL: URL? = nil) {
        self.login = login
        self.avatarURL = avatarURL
    }

    /// The avatar-chip initials: the first two alphanumerics of the login, uppercased
    /// (e.g. "claude[bot]" → "CL", "maya" → "MA"). Falls back to "?" for a symbol-only or
    /// empty login so the chip is never blank.
    public var initials: String {
        let alphanumerics = login.filter { $0.isLetter || $0.isNumber }
        let two = alphanumerics.prefix(2).uppercased()
        return two.isEmpty ? "?" : two
    }

    /// GitHub marks automation accounts with a "[bot]" login suffix (e.g. "claude[bot]"). The
    /// presentation layer uses this to tint agent-authored items and badge their comments.
    public var isBot: Bool { login.hasSuffix("[bot]") }
}
