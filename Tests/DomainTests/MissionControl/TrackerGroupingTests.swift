import XCTest
@testable import Domain

/// Contract tests for `TrackerGrouping`: the tracker rail's sections and the board's columns.
final class TrackerGroupingTests: XCTestCase {

    private let issue = TrackerEntry(key: "i", isPullRequest: false)
    private let ready = TrackerEntry(key: "r", isPullRequest: true)
    private let draft = TrackerEntry(key: "d", isPullRequest: true, isDraft: true)
    private let agent = TrackerEntry(key: "a", isPullRequest: true, isDraft: true, isAgent: true)
    private let ringing = TrackerEntry(key: "n", isPullRequest: true, isAgent: true, needsYou: true)

    func testNeedsYouWinsOverEveryOtherSection() {
        XCTAssertEqual(TrackerGrouping.section(for: ringing), .needsYou)
    }

    func testAgentPullRequestWinsOverDraft() {
        XCTAssertEqual(TrackerGrouping.section(for: agent), .agentPullRequests)
    }

    func testSectionsFollowDisplayOrderAndDropEmptyOnes() {
        let groups = TrackerGrouping.groups([issue, ready, ringing])
        XCTAssertEqual(groups.map(\.kind), [.needsYou, .pullRequests, .issues])
    }

    func testEveryEntryLandsInExactlyOneSection() {
        let all = [issue, ready, draft, agent, ringing]
        let placed = TrackerGrouping.groups(all).flatMap(\.entries).map(\.key)
        XCTAssertEqual(placed.sorted(), all.map(\.key).sorted())
    }

    func testBoardKeepsAllFourColumnsEvenWhenEmpty() {
        let board = TrackerGrouping.board([issue])
        XCTAssertEqual(board.map(\.column), [.issues, .drafts, .ready, .agent])
        XCTAssertEqual(board[0].entries.map(\.key), ["i"])
        XCTAssertTrue(board[3].entries.isEmpty)
    }

    func testBoardIgnoresNeedsYou() {
        XCTAssertEqual(TrackerGrouping.column(for: ringing), .agent)
    }
}
