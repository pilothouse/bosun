import XCTest
@testable import Domain

/// Contract tests for the pure busy-tab rule (#93 spike). They describe what `TerminalBusyPolicy`
/// promises outward — which libghostty activity signal puts a tab into the "busy" (spinner) state
/// and which takes it out — not how it works inside. Don't edit a contract test to make an
/// implementation pass; if the contract is wrong, flag it.
final class TerminalBusyPolicyTests: XCTestCase {
    func testIndeterminateProgressIsBusy() {
        // OSC 9;4 INDETERMINATE is the canonical "I'm working, no percentage" signal.
        XCTAssertTrue(TerminalBusyPolicy.isBusy(.progress(.indeterminate)))
    }

    func testInProgressPercentIsBusy() {
        // A SET below 100% is still in flight.
        XCTAssertTrue(TerminalBusyPolicy.isBusy(.progress(.set(0))))
        XCTAssertTrue(TerminalBusyPolicy.isBusy(.progress(.set(50))))
        XCTAssertTrue(TerminalBusyPolicy.isBusy(.progress(.set(99))))
    }

    func testCompletedPercentIsIdle() {
        // SET(100) means done — stop the spinner even if no explicit REMOVE follows.
        XCTAssertFalse(TerminalBusyPolicy.isBusy(.progress(.set(100))))
    }

    func testRemoveIsIdle() {
        XCTAssertFalse(TerminalBusyPolicy.isBusy(.progress(.remove)))
    }

    func testErrorIsIdle() {
        // ERROR ends the operation; the spinner is for "in progress", not for surfacing failure.
        XCTAssertFalse(TerminalBusyPolicy.isBusy(.progress(.error)))
    }

    func testPauseIsIdle() {
        // PAUSE is not actively working, so the spinner stops (a paused spinner reads as busy).
        XCTAssertFalse(TerminalBusyPolicy.isBusy(.progress(.pause)))
    }

    func testCommandFinishedIsIdle() {
        // Shell-integration command end is the stop safety-net for a tracked shell command.
        XCTAssertFalse(TerminalBusyPolicy.isBusy(.commandFinished))
    }
}
