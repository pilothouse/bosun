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
