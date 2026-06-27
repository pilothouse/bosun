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
/// collections (`comments`/`checks`/`files`) empty; a detail fetch fills them in. `tasks` is
/// derived from `body` via `GitHubTask.parse`, and PR-only fields (`branch`/`additions`/`deletions`/
/// `files`) stay nil/empty for issues. Pure value type — the presentation layer adds colors and glyphs.
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
    /// The files a PR changed (path + counts + change type). PR-only and detail-hydrated, like
    /// `checks`. Optional so an older cache written before this key still decodes (to nil); the
    /// presentation layer treats nil as "none".
    public let files: [GitHubFile]?
    public let tasks: [GitHubTask]
    /// The number of this item's sub-issue parent in the same repo, or nil when it isn't a
    /// sub-issue. Carried from the list fetch (GitHub's GraphQL `parent`) so the panel can group
    /// "By parent". Optional so an older cache missing the key still decodes (to nil).
    public let parentNumber: Int?
    /// The people assigned to this item. Carried by both the list and detail fetches, so the
    /// detail pane's metadata section is complete on the instantly-shown lead row and the body
    /// doesn't jump when the detail lands. Optional so an older cache written before this key still
    /// decodes (to nil); the presentation layer treats nil as "none".
    public let assignees: [GitHubActor]?
    /// The title of this item's milestone, or nil when it has none. Carried by the list fetch too
    /// (same anti-jump reason as `assignees`); optional for the same cache-compatibility reason.
    public let milestone: String?
    /// Label name → hex color (e.g. `"d73a4a"`, no leading `#`), for the labels that carry one.
    /// Kept parallel to `labels` (rather than turning labels into objects) so the search/epic/list
    /// rules over `labels: [String]` stay untouched. Carried by *both* the list and detail fetches —
    /// so the instantly-shown lead row already has colored pills, with no recolor when the detail
    /// lands. Optional, like the above (older caches and colorless labels map to nil).
    public let labelColors: [String: String]?

    public init(id: String, number: Int, kind: GitHubItemKind, title: String,
                state: GitHubItemState, author: GitHubActor, createdAt: Date, body: String,
                repositoryNameWithOwner: String, labels: [String] = [], isDraft: Bool = false,
                branch: String? = nil, additions: Int? = nil, deletions: Int? = nil,
                comments: [GitHubComment] = [], checks: [GitHubCheck] = [],
                files: [GitHubFile]? = nil, tasks: [GitHubTask] = [], parentNumber: Int? = nil,
                assignees: [GitHubActor]? = nil, milestone: String? = nil,
                labelColors: [String: String]? = nil) {
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
        self.files = files
        self.tasks = tasks
        self.parentNumber = parentNumber
        self.assignees = assignees
        self.milestone = milestone
        self.labelColors = labelColors
    }
}
