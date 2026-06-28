import Domain
import Foundation

/// GraphQL DTOs for the actor/label fields of an issue/PR node. Split out of `GitHubAPIClient` to
/// keep that file under the line-length cap; `ItemNode` references them through the module.
/// `internal`, not `private`, so the cross-file references resolve.

/// A GitHub actor (author or assignee): login + optional avatar.
struct AuthorDTO: Decodable {
    let login: String
    let avatarUrl: String?
    func toDomain() -> GitHubActor {
        GitHubActor(login: login, avatarURL: avatarUrl.flatMap(URL.init(string:)))
    }
}

/// A connection of actors (e.g. `assignees`) — same node shape as the author, reusing `AuthorDTO`.
struct ActorConnection: Decodable {
    let nodes: [AuthorDTO]
}

struct LabelConnection: Decodable {
    let nodes: [Label]
    /// `color` is GitHub's `Label.color`: a 6-char hex string with no leading `#`. Optional so a
    /// response (or test fixture) that selects only `name` still decodes.
    struct Label: Decodable { let name: String; let color: String? }
}

/// One issue/PR node. The list queries fill the lead fields; the detail query also sets
/// `typeName` and the PR's `commits` rollup. PR-only fields stay nil for issues. Lives here (not in
/// `GitHubAPIClient`) for the same line-cap reason as the DTOs above; the `commits`/`files`/context
/// connection DTOs it references stay `internal` in `GitHubAPIClient`, so the cross-file refs resolve.
struct ItemNode: Decodable {
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
    let mergeable: String?
    let mergeStateStatus: String?
    let baseRefName: String?
    let typeName: String?
    let commits: CommitConnection?
    let files: FilesConnection?
    let parent: ParentRef?
    let assignees: ActorConnection?
    let milestone: MilestoneRef?

    /// The sub-issue parent, when this issue is one — only its `number` is needed to group locally.
    struct ParentRef: Decodable { let number: Int }
    /// The item's milestone — only its `title` is surfaced.
    struct MilestoneRef: Decodable { let title: String }

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, createdAt, state, author, labels
        case isDraft, additions, deletions, headRefName, commits, files, parent
        case assignees, milestone, mergeable, mergeStateStatus, baseRefName
        case typeName = "__typename"
    }

    /// CI checks pulled from the PR's status-check rollup (empty for issues / no checks).
    var rollupChecks: [GitHubCheck] {
        commits?.nodes.first?.commit.statusCheckRollup?.contexts.nodes.compactMap { $0.toDomain() } ?? []
    }

    /// The files a PR changed (empty for issues, or a PR whose `files` GraphQL field is absent).
    var changedFiles: [GitHubFile] {
        files?.nodes.map { $0.toDomain() } ?? []
    }

    func toDomain(kind: GitHubItemKind, repoNameWithOwner: String,
                  comments: [GitHubComment] = [], checks: [GitHubCheck] = [],
                  files: [GitHubFile]? = nil) -> GitHubItem {
        GitHubItem(
            id: id, number: number, kind: kind, title: title,
            state: GitHubItem.state(fromGraphQL: state),
            author: author?.toDomain() ?? .ghost,
            createdAt: createdAt, body: body, repositoryNameWithOwner: repoNameWithOwner,
            labels: labels?.nodes.map(\.name) ?? [], isDraft: isDraft ?? false,
            branch: headRefName, additions: additions, deletions: deletions,
            comments: comments, checks: checks, files: files,
            tasks: GitHubTask.parse(markdownBody: body), parentNumber: parent?.number,
            assignees: assignees?.nodes.map { $0.toDomain() },
            milestone: milestone?.title,
            labelColors: labelColorMap,
            mergeable: mergeableBool, mergeStateStatus: mergeStateStatus, baseRefName: baseRefName)
    }

    /// GitHub's `MergeableState` enum (MERGEABLE/CONFLICTING/UNKNOWN) flattened to the Domain's
    /// tri-state `Bool?`: known-good → true, known-conflicting → false, not-yet-computed → nil.
    private var mergeableBool: Bool? {
        switch mergeable?.uppercased() {
        case "MERGEABLE":   return true
        case "CONFLICTING": return false
        default:            return nil
        }
    }

    /// Label name → hex color for the labels that carry one. Nil when none does — keeps items
    /// (and the cache) from gaining an empty dictionary. Both the list and detail queries select
    /// `color`, so a lead row carries it too.
    private var labelColorMap: [String: String]? {
        let pairs = labels?.nodes.compactMap { node in node.color.map { (node.name, $0) } } ?? []
        return pairs.isEmpty ? nil : Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}
