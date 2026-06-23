import Domain
import Foundation

/// Posts a comment on an issue/PR. One collaborator (the `GitHubAPI` port) — the only business
/// rule is "don't post an empty comment", so it trims the body and rejects a blank one before
/// touching the network. The view/controller calls this rather than the client directly, keeping
/// the write behind the same seam the read path uses (so a fake stands in for it under test).
public struct AddCommentUseCase: Sendable {
    private let api: GitHubAPI

    public init(api: GitHubAPI) {
        self.api = api
    }

    /// Returns the comment as GitHub stored it (so the UI can append the canonical author/time).
    /// Throws `AddCommentError.empty` for a whitespace-only body; otherwise posts the trimmed text.
    public func callAsFunction(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AddCommentError.empty }
        return try await api.addComment(owner: owner, repo: repo, number: number, body: trimmed)
    }
}
