import Foundation

/// The authenticated GitHub user (`viewer` / REST `/user`). Pure value type — no transport,
/// no UI. The App layer maps it to whatever the titlebar/account chip needs.
public struct GitHubUser: Sendable, Equatable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?

    public init(login: String, name: String? = nil, avatarURL: URL? = nil) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}
