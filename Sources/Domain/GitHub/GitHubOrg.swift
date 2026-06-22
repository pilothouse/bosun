import Foundation

/// An organization the viewer belongs to, with its repositories. The orgs panel renders one of
/// these per top-level group.
public struct GitHubOrg: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let login: String
    public let name: String?
    public let repositories: [GitHubRepo]

    public init(id: String, login: String, name: String? = nil, repositories: [GitHubRepo] = []) {
        self.id = id
        self.login = login
        self.name = name
        self.repositories = repositories
    }
}
