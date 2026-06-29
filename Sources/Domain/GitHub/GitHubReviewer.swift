import Foundation

/// A reviewer's state on a pull request. GitHub splits this across two signals: a still-open
/// *review request* (no verdict yet) is `.pending`; a *submitted review* carries one of the other
/// four. The `String` raw value gives the local cache a stable, readable on-disk form.
public enum GitHubReviewState: String, Sendable, Equatable, Codable {
    case pending
    case approved
    case changesRequested
    case commented
    case dismissed

    /// Map GitHub's GraphQL `PullRequestReviewState` (`APPROVED`/`CHANGES_REQUESTED`/`COMMENTED`/
    /// `DISMISSED`/`PENDING`). An unrecognized state reads as `.commented` — the neutral "left a
    /// review" fallback, so a future state is never mistaken for an approval or a change request.
    public init(graphQL: String) {
        switch graphQL.uppercased() {
        case "APPROVED":          self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "DISMISSED":         self = .dismissed
        case "PENDING":           self = .pending
        default:                  self = .commented
        }
    }
}

/// A reviewer on a pull request: identity + avatar (mirroring `GitHubActor`) plus their review
/// `state`. PR-only and detail-hydrated; the presentation layer derives initials/colors from the
/// login and a badge from the state.
public struct GitHubReviewer: Sendable, Equatable, Codable {
    public let login: String
    public let avatarURL: URL?
    public let state: GitHubReviewState

    public init(login: String, avatarURL: URL? = nil, state: GitHubReviewState) {
        self.login = login
        self.avatarURL = avatarURL
        self.state = state
    }

    /// Reuse the canonical actor rules so a reviewer chip's initials/bot-badge match how the same
    /// account renders as an author or assignee.
    public var initials: String { GitHubActor(login: login).initials }
    public var isBot: Bool { GitHubActor(login: login).isBot }

    /// Combine GitHub's two reviewer signals into one list, one entry per login. A currently
    /// *requested* reviewer is `.pending` and comes first (a re-request overrides any prior review,
    /// and keeps the reviewer removable); the remaining `reviews` then carry their submitted state.
    /// Repeated logins collapse to the first occurrence.
    public static func merge(requested: [GitHubActor],
                             reviews: [(GitHubActor, GitHubReviewState)]) -> [GitHubReviewer] {
        var result: [GitHubReviewer] = []
        var seen: Set<String> = []
        for actor in requested where seen.insert(actor.login).inserted {
            result.append(GitHubReviewer(login: actor.login, avatarURL: actor.avatarURL, state: .pending))
        }
        for (actor, state) in reviews where seen.insert(actor.login).inserted {
            result.append(GitHubReviewer(login: actor.login, avatarURL: actor.avatarURL, state: state))
        }
        return result
    }
}
