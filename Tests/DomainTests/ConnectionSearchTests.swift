import XCTest
@testable import Domain

/// Contract tests for the pure connection-search rule. They describe what `ConnectionSearch`
/// promises outward — whether a query matches a connection across the fields the rail searches
/// (its name and meta) — not how it works inside. The rule takes plain strings so Domain needn't
/// know the App's presentation `Connection` type. Don't edit a contract test to make an
/// implementation pass; if the contract is wrong, flag it.
final class ConnectionSearchTests: XCTestCase {

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(ConnectionSearch.matches(query: "", in: "anything", "host"),
                      "an empty query is the unfiltered list — it matches every row")
    }

    func testWhitespaceOnlyQueryMatchesEverything() {
        XCTAssertTrue(ConnectionSearch.matches(query: "   ", in: "prod-web", "1.2.3.4"),
                      "a query that is only whitespace is treated as empty")
    }

    func testMatchesNameCaseInsensitively() {
        XCTAssertTrue(ConnectionSearch.matches(query: "prod", in: "PROD-web", "10.0.0.1"))
        XCTAssertTrue(ConnectionSearch.matches(query: "WEB", in: "prod-web", "10.0.0.1"))
    }

    func testMatchesMetaWhenNameDoesNot() {
        // The query hits only the second field (an SSH host / a folder path), not the name.
        XCTAssertTrue(ConnectionSearch.matches(query: "example.com", in: "Staging", "deploy@example.com"))
        XCTAssertTrue(ConnectionSearch.matches(query: "Projects", in: "Work", "/Users/me/Projects/app"))
    }

    func testMatchesDiacriticInsensitively() {
        XCTAssertTrue(ConnectionSearch.matches(query: "munchen", in: "München box", "de.example.com"))
        XCTAssertTrue(ConnectionSearch.matches(query: "café", in: "cafe server", "host"))
    }

    func testMatchesPartialSubstring() {
        XCTAssertTrue(ConnectionSearch.matches(query: "rod-w", in: "prod-web", "host"),
                      "a substring anywhere in a field is a match")
    }

    func testReturnsFalseWhenNoFieldContainsTheQuery() {
        XCTAssertFalse(ConnectionSearch.matches(query: "zzz", in: "prod-web", "10.0.0.1"))
    }

    func testNonEmptyQueryWithNoFieldsDoesNotMatch() {
        XCTAssertFalse(ConnectionSearch.matches(query: "prod"),
                       "with nothing to search, a real query cannot match")
        XCTAssertFalse(ConnectionSearch.matches(query: "prod", in: "", ""))
    }
}
