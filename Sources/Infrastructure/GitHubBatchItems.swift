import Application
import Domain
import Foundation

/// The aggregate org view's batched fetch. Aliases many of an org's repos into one GraphQL
/// request so the whole org's open issues/PRs come back in a handful of round-trips instead of
/// two calls per repo. Kept apart from `GitHubAPIClient` so the core adapter stays within its
/// length budget; reuses that adapter's authorized `graphQL` transport, `GraphQLValue` encoding,
/// and the shared `ItemConnection`/`ItemNode` decoders.
extension GitHubAPIClient {
    /// How many repos one aliased request fetches. Bounded so a single query stays well within
    /// GraphQL node/complexity limits while still collapsing most orgs into one or two requests.
    private static let batchSize = 15

    public func batchItems(owner: String, repos: [String], kind: GitHubItemKind,
                           states: Set<GitHubItemState>) async throws -> [GitHubRepoItems] {
        guard !repos.isEmpty else { return [] }
        let requested = GitHubItemStates.requested(for: kind, selected: states)
        let tokens = requested.map(GitHubItemStates.graphQLToken).sorted()  // stable variable content
        var results: [GitHubRepoItems] = []
        for chunk in repos.chunked(into: Self.batchSize) {
            let query = GitHubGraphQLQueries.batchItems(repoCount: chunk.count, kind: kind)
            var variables: [String: GraphQLValue] = ["states": .stringArray(tokens)]
            for (index, name) in chunk.enumerated() {
                variables["o\(index)"] = .string(owner)
                variables["n\(index)"] = .string(name)
            }
            let payload: BatchItemsResponse = try await graphQL(query: query, variables: variables)
            for (index, name) in chunk.enumerated() {
                // A null/absent alias is an inaccessible repo — omit it so the caller keeps its
                // cache rather than recording a spurious empty.
                guard let connection = payload.reposByAlias["r\(index)"]?.connection else { continue }
                let nameWithOwner = "\(owner)/\(name)"
                var items = connection.nodes.map { $0.toDomain(kind: kind, repoNameWithOwner: nameWithOwner) }
                // Page only the rare repo whose first page overflowed: re-fetch it fully through the
                // single-repo path (which paginates) so its slice is complete.
                if connection.pageInfo.hasNextPage {
                    items = try await self.items(owner: owner, repo: name, kind: kind, states: states).items
                }
                results.append(GitHubRepoItems(repositoryNameWithOwner: nameWithOwner, items: items))
            }
        }
        return results
    }
}

/// The aliased multi-repo batch response: each dynamic key (`r0`, `r1`, …) is one repo's
/// `repository` selection, or `null` when that repo is inaccessible. Decoded by alias so the
/// client maps `r{index}` back to the repo it asked for. Reuses `ItemConnection`/`ItemNode`, so
/// every alias node decodes exactly like the single-repo `issues`/`pullRequests` queries.
private struct BatchItemsResponse: Decodable {
    let reposByAlias: [String: RepoItemsNode]

    struct RepoItemsNode: Decodable {
        let issues: ItemConnection?
        let pullRequests: ItemConnection?
        /// The connection for whichever kind this batch queried (only one field is ever present).
        var connection: ItemConnection? { issues ?? pullRequests }
    }

    private struct AliasKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AliasKey.self)
        var result: [String: RepoItemsNode] = [:]
        for key in container.allKeys {
            // A null alias decodes to nil here — leave it out so `connection` lookup misses and
            // the client omits that repo.
            if let node = try container.decodeIfPresent(RepoItemsNode.self, forKey: key) {
                result[key.stringValue] = node
            }
        }
        reposByAlias = result
    }
}

private extension Array {
    /// Split into consecutive slices of at most `size` — the batched fetch sends one GraphQL
    /// request per chunk.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
