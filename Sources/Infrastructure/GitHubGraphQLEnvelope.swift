import Application
import Foundation

/// The GraphQL wire envelope — the request body, the `{ data, errors }` response wrapper, and the
/// page cursor — shared by `GitHubAPIClient`'s transport and the batched-items adapter that reuses
/// it. Split out of `GitHubAPIClient.swift` to keep that file under the lint's length cap; these are
/// transport shapes with no behaviour, so they read better away from the client's endpoint methods.

struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: GraphQLValue]
}

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
    /// The cursor to fetch after, or nil when this was the last page.
    var next: String? { hasNextPage ? endCursor : nil }
}

/// Namespace for reading a GraphQL body without committing to its `data` shape.
enum GraphQLEnvelope {
    /// Pull just the `errors` messages out of a GraphQL body, ignoring `data` entirely — it reads
    /// the raw bytes so it still works when the typed decode of `data` was the thing that failed.
    /// GitHub's wording here is user-actionable ("Resource protected by organization SAML
    /// enforcement. You must grant your OAuth token access to this organization."), so callers carry
    /// it verbatim into `GitHubAPIError.graphQL` rather than flattening it into a generic failure.
    static func errorMessage(in data: Data) -> String? {
        struct ErrorsOnly: Decodable { let errors: [GraphQLError]? }
        guard let envelope = try? JSONDecoder().decode(ErrorsOnly.self, from: data),
              let errors = envelope.errors, !errors.isEmpty else { return nil }
        return errors.map(\.message).joined(separator: "; ")
    }
}
