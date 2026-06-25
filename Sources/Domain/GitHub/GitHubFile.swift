import Foundation

/// One file changed by a pull request: its path, the line counts, and how it changed. Pure value
/// type — the presentation layer turns `change` into a glyph and color. PR-only and hydrated on the
/// detail fetch (the list fetch leaves a PR's files empty).
public struct GitHubFile: Sendable, Equatable, Codable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let change: GitHubFileChange

    public init(path: String, additions: Int, deletions: Int, change: GitHubFileChange) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.change = change
    }
}

/// How a file changed in a pull request. Raw values mirror GitHub's REST `status` vocabulary
/// (`removed`, not `deleted`) so the on-disk form stays stable if the fetch ever moves from GraphQL
/// (`PatchStatus`, where deletion is `DELETED`) to REST. The adapter maps the source enum onto these.
public enum GitHubFileChange: String, Sendable, Equatable, Codable {
    case added
    case modified
    case removed
    case renamed
    case copied
    case changed
}
