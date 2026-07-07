import Domain
import Foundation

/// Closes an open issue with a reason — GitHub's "Close as completed / not planned / duplicate" flow.
/// One collaborator (the `GitHubAPI` port). Whether closing is allowed is a separate concern; this
/// use case assumes the caller already gated on it (e.g. the issue must be open).
public struct CloseIssueUseCase: Sendable {
    private let api: GitHubAPI

    public init(api: GitHubAPI) {
        self.api = api
    }

    /// Close the issue with `reason`. When closing as a duplicate of `duplicateOf`, first post the
    /// `Duplicate of #N` marker comment — GitHub only *links* the duplicate when that comment exists;
    /// `state_reason=duplicate` alone doesn't. Still one collaborator (`api`). `duplicateOf` is ignored
    /// for non-duplicate reasons (and a duplicate close with no parent just skips the comment).
    public func callAsFunction(owner: String, repo: String, number: Int,
                               reason: IssueCloseReason,
                               duplicateOf: Int? = nil) async throws -> GitHubItem {
        if reason == .duplicate, let parent = duplicateOf {
            _ = try await api.addComment(owner: owner, repo: repo, number: number,
                                         body: "Duplicate of #\(parent)")
        }
        return try await api.closeIssue(owner: owner, repo: repo, number: number, reason: reason)
    }
}
