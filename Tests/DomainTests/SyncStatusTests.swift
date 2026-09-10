import XCTest
@testable import Domain

/// Contract tests for the hint line under the Settings iCloud checkbox. `message(now:)` takes the
/// clock as an argument precisely so these can pin it.
final class SyncStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOffSaysNothing() {
        // Empty is the signal the pane uses to hide the label — sync being off is the default, and a
        // default state does not need announcing.
        XCTAssertEqual(SyncStatus.off.message(now: now), "")
    }

    func testSyncingIsAnnounced() {
        XCTAssertEqual(SyncStatus.syncing.message(now: now), "Syncing…")
    }

    func testRecentSyncReadsAsJustNow() {
        let status = SyncStatus.synced(now.addingTimeInterval(-5))
        XCTAssertEqual(status.message(now: now), "Synced just now")
    }

    func testSyncWithinTheHourIsReportedInMinutes() {
        let status = SyncStatus.synced(now.addingTimeInterval(-20 * 60))
        XCTAssertEqual(status.message(now: now), "Synced 20 min ago")
    }

    func testOlderSyncFallsBackToAClockTime() {
        // The exact rendering is locale-dependent, so assert the shape rather than the string.
        let status = SyncStatus.synced(now.addingTimeInterval(-5 * 3600))
        let message = status.message(now: now)
        XCTAssertTrue(message.hasPrefix("Synced at "), message)
        XCTAssertGreaterThan(message.count, "Synced at ".count)
    }

    func testAClockThatWentBackwardsStillReadsSensibly() {
        // A stamp in the future yields a negative interval. "just now" is the least wrong answer, and
        // certainly better than "Synced -3 min ago".
        let status = SyncStatus.synced(now.addingTimeInterval(120))
        XCTAssertEqual(status.message(now: now), "Synced just now")
    }

    func testFailureIsShownVerbatimBehindOneLabel() {
        let status = SyncStatus.failed("iCloud rejected the write")
        XCTAssertEqual(status.message(now: now), "Not synced — iCloud rejected the write")
    }
}
