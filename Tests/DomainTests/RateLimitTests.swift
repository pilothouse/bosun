import XCTest
@testable import Domain

/// Contract tests for the pure rate-limit header rule. `RateLimit.parse` reads GitHub's
/// `x-ratelimit-*` response headers; `isExhausted` is the single branch callers rely on to
/// decide a 403 is a budget exhaustion rather than a permissions error.
final class RateLimitTests: XCTestCase {
    func testParsesAllThreeFields() {
        let limit = RateLimit.parse(headers: [
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "4998",
            "x-ratelimit-reset": "1700000000",
        ])
        XCTAssertEqual(limit?.limit, 5000)
        XCTAssertEqual(limit?.remaining, 4998)
        XCTAssertEqual(limit?.resetAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testHeaderLookupIsCaseInsensitive() {
        // URLSession may surface headers with different casing depending on the platform.
        let limit = RateLimit.parse(headers: [
            "X-RateLimit-Limit": "60",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "42",
        ])
        XCTAssertEqual(limit?.limit, 60)
        XCTAssertEqual(limit?.remaining, 0)
    }

    func testIsExhaustedOnlyWhenNothingRemains() {
        XCTAssertTrue(RateLimit(limit: 60, remaining: 0, resetAt: .distantFuture).isExhausted)
        XCTAssertFalse(RateLimit(limit: 60, remaining: 1, resetAt: .distantFuture).isExhausted)
    }

    func testReturnsNilWhenAnyFieldMissing() {
        XCTAssertNil(RateLimit.parse(headers: [:]))
        XCTAssertNil(RateLimit.parse(headers: [
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "4998",
            // reset missing
        ]))
    }
}
