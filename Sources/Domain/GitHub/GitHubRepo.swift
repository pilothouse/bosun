import Foundation

/// A repository with its open-work counts. `openIssues`/`openPullRequests` are kept separate
/// (the API reports them separately); the presentation layer decides how to combine them into
/// the single "open" badge the sidebar shows.
public struct GitHubRepo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let owner: String
    public let openIssues: Int
    public let openPullRequests: Int

    public init(id: String, name: String, owner: String,
                openIssues: Int, openPullRequests: Int) {
        self.id = id
        self.name = name
        self.owner = owner
        self.openIssues = openIssues
        self.openPullRequests = openPullRequests
    }

    /// `owner/name`, the form GitHub uses to address a repo in URLs and the titlebar.
    public var nameWithOwner: String { "\(owner)/\(name)" }
}
