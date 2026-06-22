import Foundation

/// Whether a work item is an issue or a pull request — the two GitHub lists the app shows.
/// The `String` raw value gives the local cache a stable, readable on-disk form.
public enum GitHubItemKind: String, Sendable, Equatable, Codable {
    case issue
    case pullRequest
}

/// The lifecycle state shared by issues and PRs. `merged` is PR-only.
public enum GitHubItemState: String, Sendable, Equatable, Codable {
    case open
    case closed
    case merged
}

/// A pull request or issue. List fetches populate the lead fields and leave the heavy
/// collections (`comments`/`checks`) empty; a detail fetch fills them in. `tasks` is derived
/// from `body` via `GitHubTask.parse`, and PR-only fields (`branch`/`additions`/`deletions`)
/// stay nil for issues. Pure value type — the presentation layer adds colors and glyphs.
public struct GitHubItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let number: Int
    public let kind: GitHubItemKind
    public let title: String
    public let state: GitHubItemState
    public let author: GitHubActor
    public let createdAt: Date
    public let body: String
    public let repositoryNameWithOwner: String
    public let labels: [String]
    public let isDraft: Bool
    public let branch: String?
    public let additions: Int?
    public let deletions: Int?
    public let comments: [GitHubComment]
    public let checks: [GitHubCheck]
    public let tasks: [GitHubTask]

    public init(id: String, number: Int, kind: GitHubItemKind, title: String,
                state: GitHubItemState, author: GitHubActor, createdAt: Date, body: String,
                repositoryNameWithOwner: String, labels: [String] = [], isDraft: Bool = false,
                branch: String? = nil, additions: Int? = nil, deletions: Int? = nil,
                comments: [GitHubComment] = [], checks: [GitHubCheck] = [],
                tasks: [GitHubTask] = []) {
        self.id = id
        self.number = number
        self.kind = kind
        self.title = title
        self.state = state
        self.author = author
        self.createdAt = createdAt
        self.body = body
        self.repositoryNameWithOwner = repositoryNameWithOwner
        self.labels = labels
        self.isDraft = isDraft
        self.branch = branch
        self.additions = additions
        self.deletions = deletions
        self.comments = comments
        self.checks = checks
        self.tasks = tasks
    }
}
