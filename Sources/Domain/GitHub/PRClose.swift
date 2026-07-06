import Foundation

/// What happened to a PR's head branch when it was closed. `notRequested` = the user closed without
/// asking to delete it; `deleted` = it was removed; `failed` = the PR still closed but the branch
/// couldn't be deleted (already gone, protected, or a permission denial), carrying GitHub's reason.
/// A `String` reason keeps this at the same "value describing the outcome" shape as `PRMergeResult`.
public enum BranchDeletionOutcome: Sendable, Equatable {
    case notRequested
    case deleted
    case failed(reason: String)
}

/// The outcome of closing a PR: the PR as GitHub stored it after the close, plus what became of its
/// head branch. Bundled into one value so the port stays at the codebase's owner/repo/number shape.
/// The `GitHubAPI` port's return type for the close write (mirrors `PRMergeResult`).
public struct PRCloseResult: Sendable, Equatable {
    public let item: GitHubItem
    public let branchDeletion: BranchDeletionOutcome

    public init(item: GitHubItem, branchDeletion: BranchDeletionOutcome) {
        self.item = item
        self.branchDeletion = branchDeletion
    }
}

/// The rules deciding whether the detail pane offers to close a PR and, if so, whether it may also
/// delete the head branch — from the fields the detail fetch carries. Pure (has `if`s → Domain, like
/// `PRMergePolicy`), so the menu-bar view and a future CLI sweep share one source of truth.
public enum PRClosePolicy {
    /// Whether a close-without-merge is offered at all: only an open pull request can be closed
    /// (a merged/closed PR has nothing to close; issues aren't handled by this control).
    public static func canClose(kind: GitHubItemKind, state: GitHubItemState) -> Bool {
        kind == .pullRequest && state == .open
    }

    /// Whether the "delete branch" option should be offered for this PR. False when there's no head
    /// branch, when it lives in a fork (`isCrossRepository`) — it can't be deleted from the base repo —
    /// or when it *is* the base branch. `isCrossRepository` is detail-hydrated, so a nil (not-yet-known)
    /// reading hides the option until the detail confirms a same-repo PR, avoiding a fork-branch flash.
    public static func branchDeletable(branch: String?, baseRefName: String?,
                                       isCrossRepository: Bool?) -> Bool {
        guard let branch, !branch.isEmpty else { return false }
        guard isCrossRepository == false else { return false }
        return branch != baseRefName
    }
}
