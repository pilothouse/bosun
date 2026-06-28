import Domain
import Foundation

/// Merges a pull request via one of GitHub's three methods. One collaborator (the `GitHubAPI`
/// port) — the second write on it after `AddCommentUseCase`. The only business rule is "a blank
/// edited commit title/message means 'use GitHub's default'": it trims both and forwards an empty
/// one as `nil` so the adapter omits it and GitHub composes its own commit text. Whether a merge is
/// *allowed* is a separate pure rule (`PRMergePolicy`) the view consults to enable the control;
/// this use case assumes the caller already gated on it and just performs the write behind the same
/// seam the read path uses (so a fake stands in for it under test).
public struct MergePullRequestUseCase: Sendable {
    private let api: GitHubAPI

    public init(api: GitHubAPI) {
        self.api = api
    }

    /// Returns the merge outcome as GitHub reported it. The request's `commitTitle`/`commitMessage`
    /// are the user's edits (ignored by GitHub for `.rebase`); a whitespace-only one is sent as `nil`.
    public func callAsFunction(owner: String, repo: String, number: Int,
                               merge: PRMergeRequest) async throws -> PRMergeResult {
        let normalized = PRMergeRequest(method: merge.method,
                                        commitTitle: Self.normalize(merge.commitTitle),
                                        commitMessage: Self.normalize(merge.commitMessage))
        return try await api.mergePullRequest(owner: owner, repo: repo, number: number, merge: normalized)
    }

    /// Trim and collapse a blank string to `nil` so the adapter omits the field entirely.
    private static func normalize(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
