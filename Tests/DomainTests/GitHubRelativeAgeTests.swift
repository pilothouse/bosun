import XCTest
@testable import Domain

/// Contract tests for the pure relative-age rule that turns a timestamp into the compact
/// "4m ago" / "3h ago" / "2w ago" strings the issue/PR lists show. `now` is injected so the
/// buckets are deterministic. Describes what the rule promises outward, not how it works inside.
final class GitHubRelativeAgeTests: XCTestCase {
    /// Build a `(from, now)` pair `seconds` apart.
    private func age(_ seconds: Int) -> String {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return GitHubRelativeAge.compact(from: now.addingTimeInterval(-Double(seconds)), now: now)
    }

    func testUnderAMinuteReadsAsJustNow() {
        XCTAssertEqual(age(0), "just now")
        XCTAssertEqual(age(59), "just now")
    }

    func testFutureOrSkewedClockReadsAsJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(GitHubRelativeAge.compact(from: now.addingTimeInterval(120), now: now), "just now")
    }

    func testMinutesBucket() {
        XCTAssertEqual(age(60), "1m ago")
        XCTAssertEqual(age(90), "1m ago")      // integer division, not rounding
        XCTAssertEqual(age(59 * 60), "59m ago")
    }

    func testHoursBucket() {
        XCTAssertEqual(age(60 * 60), "1h ago")
        XCTAssertEqual(age(23 * 3600 + 59 * 60), "23h ago")
    }

    func testDaysBucket() {
        XCTAssertEqual(age(24 * 3600), "1d ago")
        XCTAssertEqual(age(6 * 86400), "6d ago")
    }

    func testWeeksBucket() {
        XCTAssertEqual(age(7 * 86400), "1w ago")
        XCTAssertEqual(age(13 * 86400), "1w ago")
        XCTAssertEqual(age(14 * 86400), "2w ago")
        XCTAssertEqual(age(29 * 86400), "4w ago")
    }

    func testMonthsBucket() {
        XCTAssertEqual(age(30 * 86400), "1mo ago")
        XCTAssertEqual(age(59 * 86400), "1mo ago")
        XCTAssertEqual(age(60 * 86400), "2mo ago")
        XCTAssertEqual(age(364 * 86400), "12mo ago")
    }

    func testYearsBucket() {
        XCTAssertEqual(age(365 * 86400), "1y ago")
        XCTAssertEqual(age(730 * 86400), "2y ago")
    }
}
