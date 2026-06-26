import XCTest
@testable import Domain

/// Contract tests for the pure issue/PR free-text search rule. They describe what
/// `GitHubItemSearch` promises outward — whether a query matches an item across the fields the
/// list searches (its title, its number, and its labels) — not how it works inside. The rule
/// takes plain values so Domain needn't know the App's presentation `Item` type, just like
/// `ConnectionSearch`. Don't edit a contract test to make an implementation pass; if the
/// contract is wrong, flag it.
final class GitHubItemSearchTests: XCTestCase {

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "", title: "anything", number: 1, labels: []),
                      "an empty query is the unfiltered list — it matches every item")
    }

    func testWhitespaceOnlyQueryMatchesEverything() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "   ", title: "Fix bug", number: 7, labels: ["bug"]),
                      "a query that is only whitespace is treated as empty")
    }

    func testMatchesTitleCaseInsensitively() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "search", title: "Add Search field", number: 76, labels: []))
        XCTAssertTrue(GitHubItemSearch.matches(query: "ADD", title: "add search field", number: 76, labels: []))
    }

    func testMatchesPartialSubstringInTitle() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "earch", title: "Single-input text search", number: 76, labels: []),
                      "a substring anywhere in the title is a match")
    }

    func testMatchesDiacriticInsensitively() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "munchen", title: "München crash", number: 3, labels: []))
        XCTAssertTrue(GitHubItemSearch.matches(query: "café", title: "cafe outage", number: 3, labels: []))
    }

    func testMatchesByPlainNumber() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "76", title: "Unrelated title", number: 76, labels: []),
                      "typing the bare number finds the item")
    }

    func testMatchesByHashNumber() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "#76", title: "Unrelated title", number: 76, labels: []),
                      "typing #number finds the item")
    }

    func testMatchesByLabel() {
        XCTAssertTrue(GitHubItemSearch.matches(query: "feature", title: "Unrelated", number: 9,
                                               labels: ["priority: P2", "type: feature"]),
                      "a query hitting any label is a match")
    }

    func testReturnsFalseWhenNothingContainsTheQuery() {
        XCTAssertFalse(GitHubItemSearch.matches(query: "zzz", title: "Add search field", number: 76,
                                                labels: ["type: feature"]))
    }

    func testNonEmptyQueryWithEmptyFieldsDoesNotMatch() {
        XCTAssertFalse(GitHubItemSearch.matches(query: "bug", title: "", number: 0, labels: []),
                       "with nothing meaningful to search, a real query cannot match")
    }
}
