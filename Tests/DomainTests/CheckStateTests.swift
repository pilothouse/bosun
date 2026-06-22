import XCTest
@testable import Domain

/// Contract tests for the pure check-run state rule. GitHub reports a `status` and, once
/// `completed`, a `conclusion`; `CheckState.from` collapses that two-field protocol into the
/// single state the UI renders. Unknown conclusions fall back to `.neutral` rather than crash.
final class CheckStateTests: XCTestCase {
    func testInFlightStatuses() {
        XCTAssertEqual(CheckState.from(status: "queued", conclusion: nil), .queued)
        XCTAssertEqual(CheckState.from(status: "in_progress", conclusion: nil), .inProgress)
    }

    func testCompletedConclusionsMapOneForOne() {
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "success"), .success)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "failure"), .failure)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "neutral"), .neutral)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "cancelled"), .cancelled)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "skipped"), .skipped)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "timed_out"), .timedOut)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "action_required"), .actionRequired)
    }

    func testUnknownOrMissingConclusionFallsBackToNeutral() {
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: nil), .neutral)
        XCTAssertEqual(CheckState.from(status: "completed", conclusion: "brand_new_thing"), .neutral)
    }
}
