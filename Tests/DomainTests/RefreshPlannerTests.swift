import XCTest
@testable import Domain

/// Contract tests for the pure `RefreshPlanner.next` scheduling rule. It decides which single unit
/// a background auto-refresh should fetch at `now` — round-robin over the applicable units, gated
/// by a per-unit staleness interval — or nothing when nothing is due or the rate-limit budget is
/// too low. Deterministic: `now`, `lastRefreshed`, and `rateLimit` are all inputs, so there's no
/// clock to stub. Encodes the issue-#97 "gradual, never spam" rule; don't edit a contract test to
/// make an implementation pass — if the contract is wrong, flag it.
final class RefreshPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let interval: TimeInterval = 15 * 60   // 15 minutes
    private let both = RefreshPlanner.Unit.allCases

    private func rateLimit(remaining: Int, resetIn: TimeInterval) -> RateLimit {
        RateLimit(limit: 5000, remaining: remaining, resetAt: now.addingTimeInterval(resetIn))
    }

    // MARK: - Due / not-due by interval

    func testANeverRefreshedApplicableUnitIsChosen() {
        let unit = RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                       applicable: both, rateLimit: nil)
        XCTAssertNotNil(unit, "with nothing ever refreshed, a unit is due immediately")
        XCTAssertTrue(both.contains(unit!))
    }

    func testNothingIsDueBeforeTheIntervalElapses() {
        // Both units refreshed a minute ago; the interval is 15 minutes — nothing is due yet.
        let recent = now.addingTimeInterval(-60)
        let lastRefreshed = [RefreshPlanner.Unit.orgList: recent, .currentItems: recent]
        XCTAssertNil(RefreshPlanner.next(now: now, interval: interval, lastRefreshed: lastRefreshed,
                                         applicable: both, rateLimit: nil))
    }

    func testAUnitBecomesDueOnceTheIntervalHasElapsed() {
        let stale = now.addingTimeInterval(-interval)   // exactly one interval ago
        let lastRefreshed = [RefreshPlanner.Unit.orgList: stale, .currentItems: stale]
        XCTAssertNotNil(RefreshPlanner.next(now: now, interval: interval,
                                            lastRefreshed: lastRefreshed, applicable: both,
                                            rateLimit: nil))
    }

    // MARK: - Round-robin: oldest due unit first

    func testChoosesTheOldestDueUnit() {
        // orgList older than currentItems; both due → the older one wins.
        let lastRefreshed = [
            RefreshPlanner.Unit.orgList: now.addingTimeInterval(-2 * interval),
            .currentItems: now.addingTimeInterval(-interval - 30),
        ]
        XCTAssertEqual(RefreshPlanner.next(now: now, interval: interval,
                                           lastRefreshed: lastRefreshed, applicable: both,
                                           rateLimit: nil), .orgList)
    }

    func testStampingOneUnitRotatesToTheOtherNextTick() {
        // Both never refreshed: the first call returns the allCases-order winner; after stamping it,
        // the never-refreshed sibling (still nil = oldest) is chosen next — the round-robin.
        let first = RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                        applicable: both, rateLimit: nil)
        XCTAssertEqual(first, .orgList, "allCases order breaks the all-nil tie deterministically")

        let afterFirst = [first!: now]
        let second = RefreshPlanner.next(now: now, interval: interval, lastRefreshed: afterFirst,
                                         applicable: both, rateLimit: nil)
        XCTAssertEqual(second, .currentItems, "the still-never-refreshed sibling is now the oldest")
    }

    // MARK: - Applicability

    func testExcludesUnitsThatAreNotApplicable() {
        // Only .orgList is applicable (no repo/org scope open) — even though currentItems is "older",
        // it can't be chosen.
        let lastRefreshed = [RefreshPlanner.Unit.orgList: now.addingTimeInterval(-interval)]
        XCTAssertEqual(RefreshPlanner.next(now: now, interval: interval,
                                           lastRefreshed: lastRefreshed, applicable: [.orgList],
                                           rateLimit: nil), .orgList)
    }

    func testReturnsNilWhenNoUnitsAreApplicable() {
        XCTAssertNil(RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                         applicable: [], rateLimit: nil))
    }

    // MARK: - Rate-limit budget

    func testPausesWhenBudgetIsBelowTheFloorAndWindowHasNotReset() {
        let low = rateLimit(remaining: RefreshPlanner.safetyFloor - 1, resetIn: 5 * 60)
        XCTAssertNil(RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                         applicable: both, rateLimit: low),
                     "a low budget before its reset pauses auto-refresh entirely")
    }

    func testResumesOnceTheRateLimitWindowHasReset() {
        // Same low budget, but the reset time is already in the past → the window rolled over, resume.
        let resetPast = rateLimit(remaining: RefreshPlanner.safetyFloor - 1, resetIn: -1)
        XCTAssertNotNil(RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                            applicable: both, rateLimit: resetPast))
    }

    func testDoesNotPauseWhenBudgetIsAtOrAboveTheFloor() {
        let healthy = rateLimit(remaining: RefreshPlanner.safetyFloor, resetIn: 5 * 60)
        XCTAssertNotNil(RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                            applicable: both, rateLimit: healthy))
    }

    func testUnknownRateLimitIsTreatedAsAvailable() {
        XCTAssertNotNil(RefreshPlanner.next(now: now, interval: interval, lastRefreshed: [:],
                                            applicable: both, rateLimit: nil),
                        "no snapshot yet must not block the first refreshes")
    }
}
