import XCTest
@testable import Domain

/// Contract tests for the pure presentation-support rules on `GitHubActor`: the initials the
/// avatar chip shows and whether a login is an automation account. Both are derived from the
/// login alone, so the App layer never has to special-case bots or hand-author initials.
final class GitHubActorTests: XCTestCase {
    private func actor(_ login: String) -> GitHubActor { GitHubActor(login: login) }

    func testInitialsTakeFirstTwoLettersUppercased() {
        XCTAssertEqual(actor("maya").initials, "MA")
        XCTAssertEqual(actor("Octocat").initials, "OC")
    }

    func testInitialsSkipNonAlphanumericsInBotLogins() {
        XCTAssertEqual(actor("claude[bot]").initials, "CL")
        XCTAssertEqual(actor("dependabot[bot]").initials, "DE")
    }

    func testInitialsFallBackWhenNoLetters() {
        XCTAssertEqual(actor("").initials, "?")
        XCTAssertEqual(actor("…").initials, "?")
    }

    func testIsBotMatchesTheBotSuffix() {
        XCTAssertTrue(actor("claude[bot]").isBot)
        XCTAssertTrue(actor("github-actions[bot]").isBot)
    }

    func testHumansAreNotBots() {
        XCTAssertFalse(actor("maya").isBot)
        XCTAssertFalse(actor("bot-enthusiast").isBot)   // "bot" in the name, no "[bot]" suffix
    }
}
