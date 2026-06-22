import Foundation

/// A GitHub account that authored something — an item or a comment. Just identity and avatar;
/// the presentation layer derives initials and colors from the login.
public struct GitHubActor: Sendable, Equatable {
    public let login: String
    public let avatarURL: URL?

    public init(login: String, avatarURL: URL? = nil) {
        self.login = login
        self.avatarURL = avatarURL
    }
}
