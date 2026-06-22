import Foundation

/// The GraphQL documents `GitHubAPIClient` sends. Kept apart from the client so the adapter
/// reads as transport + mapping, not a wall of query text. Each is parameterized by variables
/// the client supplies (`$cursor` for keyset pagination, `$owner`/`$repo`/`$number` for scope).
enum GitHubGraphQLQueries {
    /// Viewer's organizations with their repositories and open-work counts. Paged via `$cursor`.
    static let organizations = """
    query($cursor: String) {
      viewer {
        organizations(first: 50, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            login
            name
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

    /// Open issues in a repo, newest first. Paged via `$cursor`.
    static let issues = """
    query($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        issues(first: 50, after: $cursor, states: OPEN,
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
            labels(first: 20) { nodes { name } }
          }
        }
      }
    }
    """

    /// Open pull requests in a repo, newest first, with the PR-only fields. Paged via `$cursor`.
    static let pullRequests = """
    query($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 50, after: $cursor, states: OPEN,
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
            labels(first: 20) { nodes { name } }
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
            labels(first: 20) { nodes { name } }
          }
          ... on PullRequest {
            id number title body createdAt state
            isDraft additions deletions headRefName
            author { login avatarUrl }
            labels(first: 20) { nodes { name } }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 50) {
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion startedAt completedAt }
                        ... on StatusContext { context state }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """
}
