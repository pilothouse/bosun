import Foundation

/// One of GitHub's three ways to merge a pull request. The `rawValue` is already the REST
/// `merge_method` value (`merge`/`squash`/`rebase`), so the adapter sends it straight through.
public enum PRMergeMethod: String, Sendable, Equatable, Codable, CaseIterable {
    case merge
    case squash
    case rebase

    /// The full label GitHub shows in its picker.
    public var title: String {
        switch self {
        case .merge:  return "Create a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    /// The label GitHub puts on the primary merge button for this method (differs from `title` only
    /// for `.merge`, where the button reads "Merge pull request").
    public var buttonTitle: String {
        switch self {
        case .merge:  return "Merge pull request"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    /// A rebase replays commits onto the base with no merge commit, so GitHub ignores any
    /// `commit_title`/`commit_message` — the editable commit fields only matter for the other two.
    public var usesCommitMessage: Bool { self != .rebase }
}

/// What to merge and how: the chosen `method` plus optional overrides for the merge commit's text
/// (nil → GitHub composes its own; ignored entirely for `.rebase`). Bundled into one value so the
/// port stays at the codebase's owner/repo/number/+payload shape rather than a long parameter list.
public struct PRMergeRequest: Sendable, Equatable {
    public let method: PRMergeMethod
    public let commitTitle: String?
    public let commitMessage: String?

    public init(method: PRMergeMethod, commitTitle: String? = nil, commitMessage: String? = nil) {
        self.method = method
        self.commitTitle = commitTitle
        self.commitMessage = commitMessage
    }
}

/// The outcome of a merge as GitHub reported it: whether it merged, the resulting commit `sha`
/// (nil if it didn't), and GitHub's human-readable `message`. The `GitHubAPI` port's return type.
public struct PRMergeResult: Sendable, Equatable {
    public let merged: Bool
    public let sha: String?
    public let message: String

    public init(merged: Bool, sha: String?, message: String) {
        self.merged = merged
        self.sha = sha
        self.message = message
    }
}

/// Whether the detail pane's merge control is offered, and if not, why — so the view can disable it
/// with a reason the user can act on.
public enum PRMergeAvailability: Sendable, Equatable {
    case allowed
    case blocked(reason: String)
}

/// The rule deciding whether a PR can be merged right now, from the fields the detail fetch carries.
/// Pure — one unit test, callable from the menu-bar view or a future CLI sweep alike. Lives in
/// Domain because it has `if`s (mirrors `DispatchPolicy`/`FolderPolicy`). Repo-level method
/// enablement (allow_squash/…) isn't fetched, so all three methods are offered when merging is
/// allowed; GitHub rejects a disabled method with a readable error the adapter surfaces.
public enum PRMergePolicy {
    public static func availability(kind: GitHubItemKind, state: GitHubItemState,
                                    mergeable: Bool?, mergeStateStatus: String?) -> PRMergeAvailability {
        guard kind == .pullRequest, state == .open else {
            return .blocked(reason: "Only an open pull request can be merged")
        }
        // `mergeStateStatus` carries the nuance `mergeable` can't: a draft or a branch-protection
        // block can still report `mergeable == true`, so check the status first.
        switch mergeStateStatus?.uppercased() {
        case "DRAFT":
            return .blocked(reason: "This pull request is a draft")
        case "BLOCKED":
            return .blocked(reason: "Merging is blocked (required reviews or checks)")
        default:
            break
        }
        switch mergeable {
        case .some(false):
            return .blocked(reason: "Conflicts must be resolved before merging")
        case .none:
            // GitHub computes mergeability asynchronously; nil means it isn't known yet (or this
            // token can't see it). Re-fetching the detail resolves it.
            return .blocked(reason: "Checking if this can be merged…")
        case .some(true):
            return .allowed
        }
    }
}
