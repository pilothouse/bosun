import Domain
import Foundation

/// The GraphQL documents `GitHubAPIClient` sends. Kept apart from the client so the adapter
/// reads as transport + mapping, not a wall of query text. Each is parameterized by variables
/// the client supplies (`$cursor` for keyset pagination, `$owner`/`$repo`/`$number` for scope).
enum GitHubGraphQLQueries {
    /// Viewer's organizations with their repositories and open-work counts. Paged via `$cursor`.
    /// `first: 10` (not 50) is deliberate: each org pulls `repositories(first: 100)` with two
    /// per-repo open-count aggregations, and GitHub scores a page's cost from the `first:` arguments
    /// (not the rows actually returned). Empirically a page of 13 orgs trips "Resource limits for
    /// this query exceeded" (12 is the ceiling); 10 keeps a margin and just costs one extra round-trip
    /// per 10 orgs. A too-large page failed the *whole* fetch, freezing the org panel at its cache (#81).
    static let organizations = """
    query($cursor: String) {
      viewer {
        organizations(first: 10, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            login
            name
            avatarUrl
            repositories(first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                id
                name
                owner { login }
                issues(states: OPEN) { totalCount }
                pullRequests(states: OPEN) { totalCount }
              }
            }
          }
        }
      }
    }
    """

    /// Viewer's own (user-owned) repositories with their open-work counts. `ownerAffiliations: OWNER`
    /// restricts to repos the viewer owns — not org or collaborator repos. Paged via `$cursor`.
    static let viewerRepositories = """
    query($cursor: String) {
      viewer {
        repositories(first: 100, after: $cursor, ownerAffiliations: OWNER,
                     orderBy: {field: UPDATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            name
            owner { login }
            issues(states: OPEN) { totalCount }
            pullRequests(states: OPEN) { totalCount }
          }
        }
      }
    }
    """

    /// Issues in a repo in the requested `$states` (open by default), newest first. Paged via `$cursor`.
    static let issues = """
    query($owner: String!, $repo: String!, $cursor: String, $states: [IssueState!]) {
      repository(owner: $owner, name: $repo) {
        issues(first: 50, after: $cursor, states: $states,
               orderBy: {field: CREATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            number
            title
            body
            createdAt
            state
            author { login avatarUrl }
            labels(first: 20) { nodes { name color } }
            assignees(first: 10) { nodes { login avatarUrl } }
            milestone { title }
            parent { number }
          }
        }
      }
    }
    """

    /// Pull requests in a repo in the requested `$states` (open by default), newest first, with the
    /// PR-only fields. Paged via `$cursor`.
    static let pullRequests = """
    query($owner: String!, $repo: String!, $cursor: String, $states: [PullRequestState!]) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 50, after: $cursor, states: $states,
                     orderBy: {field: CREATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            number
            title
            body
            createdAt
            state
            isDraft
            additions
            deletions
            headRefName
            author { login avatarUrl }
            labels(first: 20) { nodes { name color } }
            assignees(first: 10) { nodes { login avatarUrl } }
            milestone { title }
          }
        }
      }
    }
    """

    /// One issue or PR by number, with the PR's check-run rollup. Comments are fetched
    /// separately over REST (see `GitHubAPIClient.itemDetail`).
    static let itemDetail = """
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issueOrPullRequest(number: $number) {
          __typename
          ... on Issue {
            id number title body createdAt state
            author { login avatarUrl }
            labels(first: 20) { nodes { name color } }
            assignees(first: 10) { nodes { login avatarUrl } }
            milestone { title }
            parent { number }
          }
          ... on PullRequest {
            id number title body createdAt state
            isDraft additions deletions headRefName
            mergeable mergeStateStatus baseRefName
            author { login avatarUrl }
            labels(first: 20) { nodes { name color } }
            assignees(first: 10) { nodes { login avatarUrl } }
            milestone { title }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 50) {
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion startedAt completedAt detailsUrl }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
            files(first: 100) { nodes { path additions deletions changeType } }
          }
        }
      }
    }
    """

    /// Build the aggregate org view's batched list query: `repoCount` repos aliased into one
    /// document (`r0…r{n-1}`), each `repository(owner: $o{i}, name: $n{i})` selecting the first
    /// page of its open issues or PRs. A single shared `$states` filters them all; per-repo
    /// `$o{i}/$n{i}` keep repo names out of the query text (passed as variables, like the
    /// single-repo queries). The node fields match the per-repo `issues`/`pullRequests` queries
    /// exactly, so `ItemNode` decodes each alias node unchanged; `pageInfo` lets the client page
    /// only the repos whose first page overflowed. Newest-first, like the single-repo path.
    static func batchItems(repoCount: Int, kind: GitHubItemKind) -> String {
        let isIssue = kind == .issue
        let stateType = isIssue ? "IssueState" : "PullRequestState"
        let field = isIssue ? "issues" : "pullRequests"
        // PR-only lead fields; issues instead carry the sub-issue parent — mirrors the per-repo
        // `issues`/`pullRequests` documents so the shared `ItemNode` decoder needs no special case.
        let prFields = "isDraft\n            additions\n            deletions\n            headRefName"
        let extraFields = isIssue ? "parent { number }" : prFields

        var varDecls = ["$states: [\(stateType)!]"]
        for index in 0..<repoCount {
            varDecls.append("$o\(index): String!")
            varDecls.append("$n\(index): String!")
        }

        let aliases = (0..<repoCount).map { index in
            """
              r\(index): repository(owner: $o\(index), name: $n\(index)) {
                \(field)(first: 50, states: $states, orderBy: {field: CREATED_AT, direction: DESC}) {
                  pageInfo { hasNextPage endCursor }
                  nodes {
                    id
                    number
                    title
                    body
                    createdAt
                    state
                    \(extraFields)
                    author { login avatarUrl }
                    labels(first: 20) { nodes { name color } }
                    assignees(first: 10) { nodes { login avatarUrl } }
                    milestone { title }
                  }
                }
              }
            """
        }.joined(separator: "\n")

        return "query(\(varDecls.joined(separator: ", "))) {\n\(aliases)\n}"
    }
}
