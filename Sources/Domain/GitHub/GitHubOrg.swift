import Foundation

/// An organization the viewer belongs to, with its repositories. The orgs panel renders one of
/// these per top-level group.
public struct GitHubOrg: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let login: String
    public let name: String?
    /// The org's icon. Optional and defaulted to `nil` so existing call sites and cached JSON
    /// (which predate the field) keep decoding — a missing key reads as `nil`.
    public let avatarURL: URL?
    public let repositories: [GitHubRepo]

    public init(id: String, login: String, name: String? = nil,
                avatarURL: URL? = nil, repositories: [GitHubRepo] = []) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.repositories = repositories
    }
}
