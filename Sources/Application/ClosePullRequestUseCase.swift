import Domain
import Foundation

/// Closes a pull request without merging and, if asked, deletes its head branch — GitHub's own
/// "Close + delete branch" flow. One collaborator (the `GitHubAPI` port). The ordering *is* the
/// business rule: close first, then delete the branch, and once the PR is closed a branch-delete
/// failure is *folded into the result* rather than thrown — the PR is already closed, so the caller
/// shouldn't treat a leftover branch as a total failure. Whether closing is *allowed*, and whether the
/// branch may be deleted, are separate pure rules (`PRClosePolicy`) the view consults to offer the
/// controls; this use case assumes the caller already gated on them.
public struct ClosePullRequestUseCase: Sendable {
    private let api: GitHubAPI

    public init(api: GitHubAPI) {
        self.api = api
    }

    /// Close the PR, then (when `deleteBranch` and a non-empty `branch` are given) delete the head
    /// branch. A close failure throws — nothing changed. A branch-delete failure returns a `.failed`
    /// outcome (the close already happened) carrying a readable reason.
    public func callAsFunction(owner: String, repo: String, number: Int,
                               branch: String?, deleteBranch: Bool) async throws -> PRCloseResult {
        let item = try await api.closePullRequest(owner: owner, repo: repo, number: number)
        guard deleteBranch, let branch, !branch.isEmpty else {
            return PRCloseResult(item: item, branchDeletion: .notRequested)
        }
        do {
            try await api.deleteBranch(owner: owner, repo: repo, branch: branch)
            return PRCloseResult(item: item, branchDeletion: .deleted)
        } catch {
            return PRCloseResult(item: item, branchDeletion: .failed(reason: Self.branchDeleteMessage(for: error)))
        }
    }

    /// Turn the port's error for a failed branch delete into a short reason the pane can show beside
    /// the (already closed) PR. Maps the adapter's `GitHubAPIError` to the cases a delete actually hits:
    /// the branch is already gone (404 → `.notFound`), it's protected (422), or the token can't write.
    private static func branchDeleteMessage(for error: Error) -> String {
        switch error as? GitHubAPIError {
        case .notFound:
            return "the branch no longer exists"
        case .http(422):
            return "it's protected or still referenced"
        case .http(403), .unauthorized:
            return "you don't have permission to delete it"
        default:
            return "the branch couldn't be deleted"
        }
    }
}
