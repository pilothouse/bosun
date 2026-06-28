import Domain
import Foundation

// The REST request/response DTOs for `GitHubAPIClient` — kept in their own file so the client stays
// under the module's file-length budget (the GraphQL item DTOs already live in `GitHubItemNodeDTOs`).
// Module-internal (not `private`) only so they can live here, away from the client; nothing outside
// Infrastructure references them.

/// The `POST .../comments` request body — GitHub takes just `{ "body": "…" }`.
struct CommentBody: Encodable {
    let body: String
}

/// The `PUT .../merge` request body. The optional commit fields override the merge commit's text;
/// synthesized `Codable` uses `encodeIfPresent`, so a nil one is omitted and GitHub uses its
/// default. `CodingKeys` map to GitHub's snake_case payload.
struct MergeBody: Encodable {
    let mergeMethod: String
    let commitTitle: String?
    let commitMessage: String?

    enum CodingKeys: String, CodingKey {
        case mergeMethod = "merge_method"
        case commitTitle = "commit_title"
        case commitMessage = "commit_message"
    }
}

/// The `PATCH .../issues/{number}` request body. Every field is optional with a synthesized
/// `encodeIfPresent`, so only the fields the user changed are sent (a nil one is omitted and left
/// untouched on GitHub); `labels`/`assignees` replace the whole set. `CodingKeys` is the default
/// (these keys are already snake-case-free).
struct EditItemBody: Encodable {
    let title: String?
    let body: String?
    let labels: [String]?
    let assignees: [String]?

    init(_ edit: GitHubItemEdit) {
        title = edit.title
        body = edit.body
        labels = edit.labels
        assignees = edit.assignees
    }
}

/// The `PATCH .../issues/{number}` success body (also the shape `GET .../issues/{number}` returns) —
/// the REST issue object, which serves PRs too. Mapped to a `GitHubItem` carrying the fields an edit
/// can change; the PR-only detail fields (checks/files/mergeability) aren't in this payload and stay
/// nil/empty, so the caller layers an edit onto the already-hydrated item rather than replacing it.
struct IssueRESTDTO: Decodable {
    let number: Int
    let title: String
    let body: String?
    let state: String
    let user: UserRefDTO?
    let labels: [LabelDTO]
    let assignees: [UserRefDTO]
    let milestone: MilestoneDTO?
    let createdAt: Date
    let draft: Bool?
    let pullRequest: PullRequestRef?

    struct MilestoneDTO: Decodable { let title: String }
    /// Present only when this issue object is actually a pull request — how the REST issues endpoint
    /// distinguishes the two. Its contents don't matter here; presence does.
    struct PullRequestRef: Decodable {}

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, user, labels, assignees, milestone, draft
        case createdAt = "created_at"
        case pullRequest = "pull_request"
    }

    func toDomain(owner: String, repo: String) -> GitHubItem {
        let nameWithOwner = "\(owner)/\(repo)"
        let kind: GitHubItemKind = pullRequest != nil ? .pullRequest : .issue
        // The issues endpoint reports only open/closed (no merged), which is fine: an edit reflects the
        // fields the user changed, and a merged PR isn't editable through this path anyway.
        let domainState: GitHubItemState = state == "closed" ? .closed : .open
        let resolvedBody = body ?? ""
        let colors = Dictionary(uniqueKeysWithValues:
            labels.compactMap { label in label.color.map { (label.name, $0) } })
        return GitHubItem(
            id: "\(nameWithOwner)#\(number)", number: number, kind: kind, title: title,
            state: domainState, author: user?.toDomain() ?? .ghost, createdAt: createdAt,
            body: resolvedBody, repositoryNameWithOwner: nameWithOwner, labels: labels.map(\.name),
            isDraft: draft ?? false, tasks: GitHubTask.parse(markdownBody: resolvedBody),
            assignees: assignees.map { $0.toDomain() }, milestone: milestone?.title,
            labelColors: colors.isEmpty ? nil : colors)
    }
}

/// One repository label from `GET .../labels` (and an item's `labels[]`) — its name and hex color.
struct LabelDTO: Decodable {
    let name: String
    let color: String?

    func toDomain() -> GitHubLabel { GitHubLabel(name: name, color: color) }
}

/// The `PUT .../merge` success body — GitHub returns `{ "sha", "merged", "message" }`.
struct MergeResultDTO: Decodable {
    let sha: String?
    let merged: Bool
    let message: String

    func toDomain() -> PRMergeResult {
        PRMergeResult(merged: merged, sha: sha, message: message)
    }
}

/// One blocker from the issue-dependencies REST list — a plain issue object. Only its number and
/// (to drop cross-repo blockers) its repository's `full_name` matter here.
struct DependencyIssueDTO: Decodable {
    let number: Int
    let repository: RepoRef?

    struct RepoRef: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
}

struct UserDTO: Decodable {
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

struct CommentDTO: Decodable {
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

struct UserRefDTO: Decodable {
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
