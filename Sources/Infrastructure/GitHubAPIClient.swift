import Application
import Domain
import Foundation

/// URLSession adapter for the `GitHubAPI` port — the only place that knows GitHub's HTTP. It
/// speaks GraphQL for the nested org/repo/item fetches and REST where that's simpler (the
/// authenticated user, an item's comments). Every request is authorized with the Keychain
/// token loaded from the injected `GitHubTokenStore`; the token is never logged. HTTP status
/// codes, decode failures, and rate-limit headers are mapped to `GitHubAPIError` so the App
/// layer reacts to meaning, not transport. An actor gives free `Sendable` correctness,
/// mirroring `GitHubDeviceAuthClient`.
public actor GitHubAPIClient: GitHubAPI {
    private let tokens: GitHubTokenStore
    private let session: URLSession
    private let restBaseURL: URL
    private let graphQLURL: URL
    private let decoder: JSONDecoder

    public init(tokenStore: GitHubTokenStore,
                session: URLSession = .shared,
                restBaseURL: URL = URL(string: "https://api.github.com")!,
                graphQLURL: URL = URL(string: "https://api.github.com/graphql")!) {
        self.tokens = tokenStore
        self.session = session
        self.restBaseURL = restBaseURL
        self.graphQLURL = graphQLURL
        let decoder = JSONDecoder()
        // GitHub timestamps are ISO 8601 with a trailing Z, in both REST and GraphQL. REST
        // snake_case and GraphQL camelCase are reconciled per-DTO via CodingKeys, so we keep
        // the default key strategy (a global snake_case convert would break the GraphQL DTOs).
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - GitHubAPI

    public func currentUser() async throws -> GitHubUser {
        let dto: UserDTO = try await getOne(path: "/user")
        return dto.toDomain()
    }

    public func organizations() async throws -> [GitHubOrg] {
        var cursor: String?
        var orgs: [GitHubOrg] = []
        repeat {
            let payload: OrgsResponse = try await graphQL(
                query: GitHubGraphQLQueries.organizations,
                variables: ["cursor": cursor.map(GraphQLValue.string) ?? .null])
            let page = payload.viewer.organizations
            orgs += page.nodes.map { $0.toDomain() }
            cursor = page.pageInfo.next
        } while cursor != nil
        return orgs
    }

    public func viewerRepositories() async throws -> [GitHubRepo] {
        var cursor: String?
        var repos: [GitHubRepo] = []
        repeat {
            let payload: ViewerReposResponse = try await graphQL(
                query: GitHubGraphQLQueries.viewerRepositories,
                variables: ["cursor": cursor.map(GraphQLValue.string) ?? .null])
            let page = payload.viewer.repositories
            repos += page.nodes.map { $0.toDomain() }
            cursor = page.pageInfo.next
        } while cursor != nil
        return repos
    }

    public func items(owner: String, repo: String, kind: GitHubItemKind,
                      states: Set<GitHubItemState>) async throws -> GitHubItemList {
        let nameWithOwner = "\(owner)/\(repo)"
        let requested = GitHubItemStates.requested(for: kind, selected: states)
        let tokens = requested.map(GitHubItemStates.graphQLToken).sorted()  // stable variable content
        let bounded = GitHubItemStates.bounded(requested)
        var cursor: String?
        var items: [GitHubItem] = []
        var reachedCap = false
        repeat {
            let vars: [String: GraphQLValue] = [
                "owner": .string(owner), "repo": .string(repo),
                "cursor": cursor.map(GraphQLValue.string) ?? .null,
                "states": .stringArray(tokens),
            ]
            let page: ItemConnection
            switch kind {
            case .issue:
                let payload: IssuesResponse = try await graphQL(
                    query: GitHubGraphQLQueries.issues, variables: vars)
                page = try payload.repository.orThrowNotFound().issues
            case .pullRequest:
                let payload: PullsResponse = try await graphQL(
                    query: GitHubGraphQLQueries.pullRequests, variables: vars)
                page = try payload.repository.orThrowNotFound().pullRequests
            }
            items += page.nodes.map { $0.toDomain(kind: kind, repoNameWithOwner: nameWithOwner) }
            let next = page.pageInfo.next
            // Bound closed/merged history: stop once we have the newest `historyCap`, recording
            // whether more pages remained so the caller can surface the cap.
            if bounded && items.count >= GitHubItemStates.historyCap {
                reachedCap = next != nil
                break
            }
            cursor = next
        } while cursor != nil
        return GitHubItemList(items: items, reachedHistoryCap: reachedCap)
    }

    public func itemDetail(owner: String, repo: String, number: Int) async throws -> GitHubItem {
        let payload: ItemDetailResponse = try await graphQL(
            query: GitHubGraphQLQueries.itemDetail,
            variables: ["owner": .string(owner), "repo": .string(repo), "number": .int(number)])
        let node = try payload.repository.orThrowNotFound().issueOrPullRequest.orThrowNotFound()
        let kind: GitHubItemKind = node.typeName == "PullRequest" ? .pullRequest : .issue
        // Comments over REST exercise Link-header pagination; checks come from the GraphQL rollup.
        let comments: [CommentDTO] = try await getPaged(
            path: "/repos/\(owner)/\(repo)/issues/\(number)/comments")
        return node.toDomain(kind: kind, repoNameWithOwner: "\(owner)/\(repo)",
                             comments: comments.map { $0.toDomain() }, checks: node.rollupChecks)
    }

    public func issueDependencies(owner: String, repo: String, number: Int) async throws -> [Int] {
        // REST list of the issues this one is "blocked by". Keep only same-repo blockers — a
        // cross-repo blocker can't appear in this repo's list, and its number could collide with a
        // local one — and return their numbers to match against the list the panel renders.
        let nameWithOwner = "\(owner)/\(repo)"
        let blockers: [DependencyIssueDTO] = try await getPaged(
            path: "/repos/\(owner)/\(repo)/issues/\(number)/dependencies/blocked_by")
        return blockers
            .filter { $0.repository == nil || $0.repository?.fullName == nameWithOwner }
            .map(\.number)
    }

    public func addComment(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment {
        // The one write: REST `POST .../comments` returns the single created comment (201), which
        // decodes through the same `CommentDTO` the detail fetch uses.
        let payload = try JSONEncoder().encode(CommentBody(body: body))
        let url = restURL(path: "/repos/\(owner)/\(repo)/issues/\(number)/comments")
        let request = try await authorizedRequest(url: url, method: "POST", body: payload)
        let (data, _) = try await perform(request)
        let dto: CommentDTO = try decode(data)
        return dto.toDomain()
    }

    // MARK: - REST transport

    /// A single REST resource (no pagination), e.g. `/user`.
    private func getOne<T: Decodable>(path: String) async throws -> T {
        let request = try await authorizedRequest(url: restURL(path: path), method: "GET")
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    /// A REST list, following the `Link: rel="next"` header until the last page. `per_page=100`
    /// keeps the round trips down.
    private func getPaged<T: Decodable>(path: String) async throws -> [T] {
        var next: URL? = restURL(path: path, query: [URLQueryItem(name: "per_page", value: "100")])
        var all: [T] = []
        while let url = next {
            let request = try await authorizedRequest(url: url, method: "GET")
            let (data, response) = try await perform(request)
            all += try decode(data) as [T]
            next = GitHubPagination.nextPageURL(fromLinkHeader: response.value(forHTTPHeaderField: "Link"))
        }
        return all
    }

    private func restURL(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: restBaseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: - GraphQL transport

    private func graphQL<T: Decodable>(query: String, variables: [String: GraphQLValue]) async throws -> T {
        let body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        var request = try await authorizedRequest(url: graphQLURL, method: "POST", body: body)
        // Opt into the sub-issues schema so `Issue.parent` resolves. Harmless once the field is GA;
        // required while it's still behind the preview flag. Additive — other queries ignore it.
        request.setValue("sub_issues", forHTTPHeaderField: "GraphQL-Features")
        let (data, _) = try await perform(request)
        let envelope: GraphQLResponse<T> = try decode(data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw GitHubAPIError.transport("graphql: " + errors.map(\.message).joined(separator: "; "))
        }
        guard let payload = envelope.data else { throw GitHubAPIError.decoding("graphql: empty data") }
        return payload
    }

    // MARK: - Shared request/response handling

    private func authorizedRequest(url: URL, method: String, body: Data? = nil) async throws -> URLRequest {
        guard let token = try await tokens.load(), !token.isEmpty else {
            throw GitHubAPIError.unauthorized
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("bosun", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.transport("non-HTTP response")
        }
        try validate(http)
        return (data, http)
    }

    /// Map an HTTP status to a `GitHubAPIError`. A 403/429 is read as a rate-limit only when the
    /// `x-ratelimit-*` headers say the budget is spent — otherwise it's a plain forbidden.
    private func validate(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            let limit = RateLimit.parse(headers: stringHeaders(http))
            if http.statusCode == 429 || limit?.isExhausted == true {
                throw GitHubAPIError.rateLimited(resetAt: limit?.resetAt)
            }
            throw GitHubAPIError.http(status: http.statusCode)
        case 404:
            throw GitHubAPIError.notFound
        default:
            throw GitHubAPIError.http(status: http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubAPIError.decoding(String(describing: error))
        }
    }

    private func stringHeaders(_ http: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { result[key] = value }
        }
        return result
    }
}

// MARK: - GraphQL request/response envelopes

/// A JSON value for GraphQL variables — the scalars these queries pass, plus a string array for
/// enum-list filters (e.g. `states: [OPEN, CLOSED]`, sent as `["OPEN","CLOSED"]` which GitHub
/// coerces to the enum-typed variable).
private enum GraphQLValue: Encodable {
    case string(String)
    case int(Int)
    case stringArray([String])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .stringArray(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: GraphQLValue]
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
    /// The cursor to fetch after, or nil when this was the last page.
    var next: String? { hasNextPage ? endCursor : nil }
}

private extension Optional {
    /// Unwrap a nullable GraphQL field (`repository`, `issueOrPullRequest`) or report it missing.
    func orThrowNotFound() throws -> Wrapped {
        guard let value = self else { throw GitHubAPIError.notFound }
        return value
    }
}

// MARK: - REST DTOs

/// The `POST .../comments` request body — GitHub takes just `{ "body": "…" }`.
private struct CommentBody: Encodable {
    let body: String
}

/// One blocker from the issue-dependencies REST list — a plain issue object. Only its number and
/// (to drop cross-repo blockers) its repository's `full_name` matter here.
private struct DependencyIssueDTO: Decodable {
    let number: Int
    let repository: RepoRef?

    struct RepoRef: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
}

private struct UserDTO: Decodable {
    let login: String
    let name: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }

    func toDomain() -> GitHubUser {
        GitHubUser(login: login, name: name, avatarURL: avatarURL.flatMap(URL.init(string:)))
    }
}

private struct CommentDTO: Decodable {
    let body: String
    let createdAt: Date
    let authorAssociation: String?
    let user: UserRefDTO?

    enum CodingKeys: String, CodingKey {
        case body, user
        case createdAt = "created_at"
        case authorAssociation = "author_association"
    }

    func toDomain() -> GitHubComment {
        GitHubComment(author: user?.toDomain() ?? .ghost, createdAt: createdAt,
                      body: body, authorAssociation: authorAssociation)
    }
}

private struct UserRefDTO: Decodable {
    let login: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }

    func toDomain() -> GitHubActor {
        GitHubActor(login: login, avatarURL: avatarURL.flatMap(URL.init(string:)))
    }
}

// MARK: - GraphQL DTOs

private struct OrgsResponse: Decodable {
    let viewer: Viewer
    struct Viewer: Decodable { let organizations: Connection }
    struct Connection: Decodable { let pageInfo: PageInfo; let nodes: [OrgNode] }
}

private struct ViewerReposResponse: Decodable {
    let viewer: Viewer
    struct Viewer: Decodable { let repositories: Connection }
    struct Connection: Decodable { let pageInfo: PageInfo; let nodes: [RepoNode] }
}

private struct OrgNode: Decodable {
    let id: String
    let login: String
    let name: String?
    let avatarUrl: String?
    let repositories: RepoConnection
    struct RepoConnection: Decodable { let nodes: [RepoNode] }

    func toDomain() -> GitHubOrg {
        GitHubOrg(id: id, login: login, name: name,
                  avatarURL: avatarUrl.flatMap(URL.init(string:)),
                  repositories: repositories.nodes.map { $0.toDomain() })
    }
}

private struct RepoNode: Decodable {
    let id: String
    let name: String
    let owner: Owner
    let issues: Count
    let pullRequests: Count
    struct Owner: Decodable { let login: String }
    struct Count: Decodable { let totalCount: Int }

    func toDomain() -> GitHubRepo {
        GitHubRepo(id: id, name: name, owner: owner.login,
                   openIssues: issues.totalCount, openPullRequests: pullRequests.totalCount)
    }
}

private struct IssuesResponse: Decodable {
    let repository: Repo?
    struct Repo: Decodable { let issues: ItemConnection }
}

private struct PullsResponse: Decodable {
    let repository: Repo?
    struct Repo: Decodable { let pullRequests: ItemConnection }
}

private struct ItemConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [ItemNode]
}

private struct ItemDetailResponse: Decodable {
    let repository: Repo?
    struct Repo: Decodable { let issueOrPullRequest: ItemNode? }
}

/// One issue/PR node. The list queries fill the lead fields; the detail query also sets
/// `typeName` and the PR's `commits` rollup. PR-only fields stay nil for issues.
private struct ItemNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let body: String
    let createdAt: Date
    let state: String
    let author: AuthorDTO?
    let labels: LabelConnection?
    let isDraft: Bool?
    let additions: Int?
    let deletions: Int?
    let headRefName: String?
    let typeName: String?
    let commits: CommitConnection?
    let parent: ParentRef?

    /// The sub-issue parent, when this issue is one — only its `number` is needed to group locally.
    struct ParentRef: Decodable { let number: Int }

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, createdAt, state, author, labels
        case isDraft, additions, deletions, headRefName, commits, parent
        case typeName = "__typename"
    }

    /// CI checks pulled from the PR's status-check rollup (empty for issues / no checks).
    var rollupChecks: [GitHubCheck] {
        commits?.nodes.first?.commit.statusCheckRollup?.contexts.nodes.compactMap { $0.toDomain() } ?? []
    }

    func toDomain(kind: GitHubItemKind, repoNameWithOwner: String,
                  comments: [GitHubComment] = [], checks: [GitHubCheck] = []) -> GitHubItem {
        GitHubItem(
            id: id, number: number, kind: kind, title: title,
            state: GitHubItem.state(fromGraphQL: state),
            author: author?.toDomain() ?? .ghost,
            createdAt: createdAt, body: body, repositoryNameWithOwner: repoNameWithOwner,
            labels: labels?.nodes.map(\.name) ?? [], isDraft: isDraft ?? false,
            branch: headRefName, additions: additions, deletions: deletions,
            comments: comments, checks: checks, tasks: GitHubTask.parse(markdownBody: body),
            parentNumber: parent?.number)
    }
}

private struct AuthorDTO: Decodable {
    let login: String
    let avatarUrl: String?
    func toDomain() -> GitHubActor {
        GitHubActor(login: login, avatarURL: avatarUrl.flatMap(URL.init(string:)))
    }
}

private struct LabelConnection: Decodable {
    let nodes: [Label]
    struct Label: Decodable { let name: String }
}

private struct CommitConnection: Decodable {
    let nodes: [CommitNode]
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let contexts: ContextConnection }
    struct ContextConnection: Decodable { let nodes: [ContextNode] }
}

/// A status-check rollup context — either a modern `CheckRun` or a legacy commit `StatusContext`.
/// `__typename` discriminates; the irrelevant fields decode as nil.
private struct ContextNode: Decodable {
    let typeName: String
    let name: String?
    let status: String?
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let context: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case name, status, conclusion, startedAt, completedAt, context, state
    }

    func toDomain() -> GitHubCheck? {
        switch typeName {
        case "CheckRun":
            guard let name else { return nil }
            // GraphQL enums are UPPER_SNAKE; CheckState.from is REST-canonical lowercase.
            return GitHubCheck(name: name,
                               state: CheckState.from(status: status?.lowercased() ?? "",
                                                      conclusion: conclusion?.lowercased()),
                               durationSeconds: duration)
        case "StatusContext":
            guard let context else { return nil }
            return GitHubCheck(name: context, state: Self.state(fromStatus: state), durationSeconds: nil)
        default:
            return nil
        }
    }

    private var duration: Int? {
        guard let startedAt, let completedAt else { return nil }
        return Int(completedAt.timeIntervalSince(startedAt))
    }

    /// Legacy commit-status `StatusState` (UPPERCASE) → `CheckState`.
    private static func state(fromStatus state: String?) -> CheckState {
        switch state {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        case "PENDING": return .inProgress
        default: return .queued
        }
    }
}

private extension GitHubActor {
    /// GitHub renders a deleted account as "ghost"; mirror that when an author is null.
    static let ghost = GitHubActor(login: "ghost")
}

private extension GitHubItem {
    /// GraphQL `IssueState`/`PullRequestState` (UPPERCASE) → domain state.
    static func state(fromGraphQL value: String) -> GitHubItemState {
        switch value {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .open
        }
    }
}
