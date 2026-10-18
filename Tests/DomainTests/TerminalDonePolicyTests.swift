import XCTest
@testable import Domain

/// Contract tests for the pure "done" rule (#103): when a session that stopped working should be
/// marked as finished-but-unseen. They describe what `TerminalDonePolicy` promises outward, not how
/// it works inside. Don't edit a contract test to make an implementation pass; if the contract is
/// wrong, flag it.
final class TerminalDonePolicyTests: XCTestCase {
    func testUnfocusedSessionThatStopsWorkingBecomesDone() {
        // The core of #103: a Claude turn ends in a tile you're not looking at.
        XCTAssertTrue(TerminalDonePolicy.next(isDone: false, wasVisiblyBusy: true, isBusy: false,
                                              isFocused: false, timedOut: false))
    }

    func testFocusedSessionNeverBecomesDone() {
        // You watched it finish, so there is nothing to catch up on.
        XCTAssertFalse(TerminalDonePolicy.next(isDone: false, wasVisiblyBusy: true, isBusy: false,
                                               isFocused: true, timedOut: false))
    }

    func testBackstopTimeoutIsNotDone() {
        // The 10-minute busy backstop clears a tab that went silent; it doesn't know the run finished.
        XCTAssertFalse(TerminalDonePolicy.next(isDone: false, wasVisiblyBusy: true, isBusy: false,
                                               isFocused: false, timedOut: true))
    }

    func testWorkTooShortToShowNeverBecomesDone() {
        // A command that ended before the busy debounce showed anything (e.g. `ls`) must not flash done.
        XCTAssertFalse(TerminalDonePolicy.next(isDone: false, wasVisiblyBusy: false, isBusy: false,
                                               isFocused: false, timedOut: false))
    }

    func testStartingWorkClearsDone() {
        XCTAssertFalse(TerminalDonePolicy.next(isDone: true, wasVisiblyBusy: false, isBusy: true,
                                               isFocused: false, timedOut: false))
    }

    func testQuietSignalKeepsTheCurrentState() {
        // An idle → idle signal (a repeated REMOVE, a prompt after a short command) changes nothing.
        XCTAssertTrue(TerminalDonePolicy.next(isDone: true, wasVisiblyBusy: false, isBusy: false,
                                              isFocused: false, timedOut: false))
        XCTAssertFalse(TerminalDonePolicy.next(isDone: false, wasVisiblyBusy: false, isBusy: false,
                                               isFocused: false, timedOut: false))
    }
}
