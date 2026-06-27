import XCTest
@testable import Domain

/// Contract tests for the pure OAuth-app link rule. They describe what `GitHubOAuthApp` promises
/// outward — the GitHub page where a user grants/revokes the app's access — not how it's built.
/// Don't edit a contract test to make an implementation pass; if the contract is wrong, flag it.
final class GitHubOAuthAppTests: XCTestCase {

    func testConnectionsURLForTheShippedClientID() {
        XCTAssertEqual(
            GitHubOAuthApp.connectionsURL(clientID: "Ov23liOrAKfzcXed8ucm").absoluteString,
            "https://github.com/settings/connections/applications/Ov23liOrAKfzcXed8ucm",
            "the link points at the OAuth app's own connections page")
    }

    func testConnectionsURLReflectsAnOverriddenClientID() {
        // An app swapped in via BOSUN_GITHUB_CLIENT_ID must point the link at *that* app, not the default.
        XCTAssertEqual(
            GitHubOAuthApp.connectionsURL(clientID: "Iv1_custom_app").absoluteString,
            "https://github.com/settings/connections/applications/Iv1_custom_app")
    }
}
