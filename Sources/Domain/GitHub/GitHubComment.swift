import Foundation

/// A comment on an issue or pull request. `authorAssociation` (OWNER, MEMBER, CONTRIBUTOR…)
/// is what the UI turns into the little role badge next to a name.
public struct GitHubComment: Sendable, Equatable, Codable {
    public let author: GitHubActor
    public let createdAt: Date
    public let body: String
    public let authorAssociation: String?

    public init(author: GitHubActor, createdAt: Date, body: String,
                authorAssociation: String? = nil) {
        self.author = author
        self.createdAt = createdAt
        self.body = body
        self.authorAssociation = authorAssociation
    }
}
