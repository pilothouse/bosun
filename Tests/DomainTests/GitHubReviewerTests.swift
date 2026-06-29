import XCTest
@testable import Domain

/// Contract tests for `GitHubReviewer`: the GraphQL review-state mapping, the pure rule that merges
/// GitHub's two separate signals (still-pending `reviewRequests` + per-author `latestReviews`) into
/// one reviewer list, and the actor-derived `initials`/`isBot` it shares with `GitHubActor`.
final class GitHubReviewerTests: XCTestCase {
    private func actor(_ login: String) -> GitHubActor { GitHubActor(login: login) }

    // MARK: State mapping

    func testGraphQLStateMapsTheKnownReviewStates() {
        XCTAssertEqual(GitHubReviewState(graphQL: "APPROVED"), .approved)
        XCTAssertEqual(GitHubReviewState(graphQL: "CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(GitHubReviewState(graphQL: "COMMENTED"), .commented)
        XCTAssertEqual(GitHubReviewState(graphQL: "DISMISSED"), .dismissed)
        XCTAssertEqual(GitHubReviewState(graphQL: "PENDING"), .pending)
    }

    func testGraphQLStateFallsBackToCommentedForAnUnknownState() {
        // A future/unseen state shouldn't be read as an approval or a change request — "commented"
        // is the neutral "left a review" fallback.
        XCTAssertEqual(GitHubReviewState(graphQL: "SOMETHING_NEW"), .commented)
    }

    // MARK: Merge rule

    func testRequestedReviewersBecomePendingInOrder() {
        let merged = GitHubReviewer.merge(requested: [actor("alex"), actor("sam")], reviews: [])
        XCTAssertEqual(merged, [
            GitHubReviewer(login: "alex", state: .pending),
            GitHubReviewer(login: "sam", state: .pending),
        ])
    }

    func testReviewsCarryTheirStateAfterTheRequestedOnes() {
        let merged = GitHubReviewer.merge(
            requested: [actor("alex")],
            reviews: [(actor("maya"), .approved), (actor("raj"), .changesRequested)])
        XCTAssertEqual(merged, [
            GitHubReviewer(login: "alex", state: .pending),
            GitHubReviewer(login: "maya", state: .approved),
            GitHubReviewer(login: "raj", state: .changesRequested),
        ])
    }

    func testARequestedReviewerOverridesAPriorReviewOfTheirs() {
        // A re-requested reviewer who already approved shows as pending again (and stays removable);
        // only one chip per login.
        let merged = GitHubReviewer.merge(
            requested: [actor("maya")],
            reviews: [(actor("maya"), .approved)])
        XCTAssertEqual(merged, [GitHubReviewer(login: "maya", state: .pending)])
    }

    func testDedupesRepeatedLogins() {
        let merged = GitHubReviewer.merge(requested: [actor("alex"), actor("alex")], reviews: [])
        XCTAssertEqual(merged, [GitHubReviewer(login: "alex", state: .pending)])
    }

    func testCarriesTheActorAvatar() {
        let url = URL(string: "https://avatars.githubusercontent.com/u/9?v=4")
        let merged = GitHubReviewer.merge(
            requested: [GitHubActor(login: "sam", avatarURL: url)], reviews: [])
        XCTAssertEqual(merged.first?.avatarURL, url)
    }

    // MARK: Actor-derived presentation rules (mirror GitHubActor)

    func testInitialsAndIsBotMirrorTheActorRule() {
        XCTAssertEqual(GitHubReviewer(login: "maya", state: .pending).initials, "MA")
        XCTAssertEqual(GitHubReviewer(login: "claude[bot]", state: .commented).initials, "CL")
        XCTAssertTrue(GitHubReviewer(login: "github-actions[bot]", state: .commented).isBot)
        XCTAssertFalse(GitHubReviewer(login: "maya", state: .approved).isBot)
    }
}
