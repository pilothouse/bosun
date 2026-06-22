import XCTest
@testable import Domain

/// Contract tests for the pure REST `Link`-header pagination rule. They describe what
/// `GitHubPagination` promises outward — find the `rel="next"` URL or nothing — not how it
/// scans the header. Don't edit a contract test to make an implementation pass.
final class GitHubPaginationTests: XCTestCase {
    func testReturnsNextWhenPresentAlongsideLast() {
        let header = "<https://api.github.com/repos/o/r/issues?page=2>; rel=\"next\", " +
                     "<https://api.github.com/repos/o/r/issues?page=9>; rel=\"last\""
        XCTAssertEqual(GitHubPagination.nextPageURL(fromLinkHeader: header),
                       URL(string: "https://api.github.com/repos/o/r/issues?page=2"))
    }

    func testReturnsNilWhenOnlyLastAndPrevPresent() {
        let header = "<https://api.github.com/repos/o/r/issues?page=1>; rel=\"prev\", " +
                     "<https://api.github.com/repos/o/r/issues?page=9>; rel=\"last\""
        XCTAssertNil(GitHubPagination.nextPageURL(fromLinkHeader: header))
    }

    func testPicksNextOutOfFourRels() {
        let header = "<https://api.github.com/x?page=1>; rel=\"prev\", " +
                     "<https://api.github.com/x?page=3>; rel=\"next\", " +
                     "<https://api.github.com/x?page=1>; rel=\"first\", " +
                     "<https://api.github.com/x?page=9>; rel=\"last\""
        XCTAssertEqual(GitHubPagination.nextPageURL(fromLinkHeader: header),
                       URL(string: "https://api.github.com/x?page=3"))
    }

    func testToleratesCommasInsideTheURLQuery() {
        // A label filter can put commas inside the URL itself — splitting on "," would break.
        let header = "<https://api.github.com/x?labels=bug,wip&page=2>; rel=\"next\""
        XCTAssertEqual(GitHubPagination.nextPageURL(fromLinkHeader: header),
                       URL(string: "https://api.github.com/x?labels=bug,wip&page=2"))
    }

    func testReturnsNilForNilEmptyOrMalformed() {
        XCTAssertNil(GitHubPagination.nextPageURL(fromLinkHeader: nil))
        XCTAssertNil(GitHubPagination.nextPageURL(fromLinkHeader: ""))
        XCTAssertNil(GitHubPagination.nextPageURL(fromLinkHeader: "garbage; rel=\"next\""))
    }
}
