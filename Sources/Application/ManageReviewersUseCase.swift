import Domain
import Foundation

/// Requests or removes reviewers on a PR. One collaborator (the `GitHubAPI` port) — the only
/// business rule is "don't make an empty request", so it rejects an empty `logins` set before
/// touching the network. The view/controller calls this rather than the client directly, keeping
/// the write behind the same seam the read path uses (so a fake stands in for it under test).
public struct ManageReviewersUseCase: Sendable {
    private let api: GitHubAPI

    public init(api: GitHubAPI) {
        self.api = api
    }

    /// Request reviews from `logins`, returning the PR's requested (pending) reviewers after the
    /// change. Throws `ManageReviewersError.empty` when `logins` is empty (nothing to request).
    public func request(owner: String, repo: String, number: Int,
                        logins: [String]) async throws -> [GitHubReviewer] {
        guard !logins.isEmpty else { throw ManageReviewersError.empty }
        return try await api.requestReviewers(owner: owner, repo: repo, number: number, logins: logins)
    }

    /// Cancel pending requests for `logins`, returning the requested reviewers that remain. Throws
    /// `ManageReviewersError.empty` when `logins` is empty (nothing to remove).
    public func remove(owner: String, repo: String, number: Int,
                       logins: [String]) async throws -> [GitHubReviewer] {
        guard !logins.isEmpty else { throw ManageReviewersError.empty }
        return try await api.removeRequestedReviewers(owner: owner, repo: repo, number: number, logins: logins)
    }
}
