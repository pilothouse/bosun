import Foundation

/// One repo's slice of an org-wide batch fetch: the repo it belongs to and the items that came
/// back for it. The batched `GitHubAPI.batchItems` returns one of these per repo that *resolved*
/// — an inaccessible (null) repo is omitted rather than reported empty, so the caller can tell
/// "fetched, genuinely no open work" (an entry with empty `items`) apart from "couldn't fetch"
/// (no entry) and leave the latter's cache untouched. Pure value type; the items already carry
/// their `repositoryNameWithOwner`, repeated here so callers group without re-parsing.
public struct GitHubRepoItems: Sendable, Equatable {
    public let repositoryNameWithOwner: String
    public let items: [GitHubItem]

    public init(repositoryNameWithOwner: String, items: [GitHubItem]) {
        self.repositoryNameWithOwner = repositoryNameWithOwner
        self.items = items
    }
}
