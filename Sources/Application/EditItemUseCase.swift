import Domain
import Foundation

/// Edits an issue/PR's title/body/labels/assignees. One collaborator (the `GitHubAPI` port) — the
/// third write on it after `AddCommentUseCase`/`MergePullRequestUseCase`. Two business rules: a title
/// being edited may not be blank (GitHub rejects it), and an edit that changes nothing must not issue
/// a no-op write. It trims an edited title and rejects a whitespace-only one before touching the
/// network; the body is passed through untouched (an empty body is a valid edit — clearing it). The
/// view/controller calls this rather than the client directly, keeping the write behind the same seam
/// the read path uses (so a fake stands in for it under test).
public struct EditItemUseCase: Sendable {
    private let api: GitHubAPI

    public init(api: GitHubAPI) {
        self.api = api
    }

    /// Returns the item as GitHub stored it (so the UI can reflect the canonical labels/assignees).
    /// Throws `EditItemError.noChanges` for an empty edit and `.emptyTitle` for a blank edited title;
    /// otherwise forwards the edit (with the title trimmed) to the API.
    public func callAsFunction(owner: String, repo: String, number: Int,
                               edit: GitHubItemEdit) async throws -> GitHubItem {
        guard !edit.isEmpty else { throw EditItemError.noChanges }
        var normalized = edit
        if let title = edit.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EditItemError.emptyTitle }
            normalized.title = trimmed
        }
        return try await api.editItem(owner: owner, repo: repo, number: number, edit: normalized)
    }
}
