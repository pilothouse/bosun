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

    // MARK: state(_:) — the richer mapping that drives indeterminate-vs-determinate rendering (#94)

    func testIndeterminateMapsToIndeterminateState() {
        // No percentage → the spinning indicator, distinct from a determinate ring.
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.indeterminate)), .indeterminate)
    }

    func testInProgressPercentMapsToDeterminateState() {
        // A SET below 100% carries a real percentage for the determinate ring.
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.set(0))), .determinate(0))
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.set(50))), .determinate(50))
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.set(99))), .determinate(99))
    }

    func testNegativePercentClampsToZero() {
        // libghostty passes -1 when no percentage was given; treat it as a determinate 0%, never
        // a negative ring value.
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.set(-1))), .determinate(0))
    }

    func testCompletedAndStoppedSignalsMapToIdle() {
        // Everything that stops the spinner reduces to a single idle state.
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.set(100))), .idle)
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.remove)), .idle)
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.error)), .idle)
        XCTAssertEqual(TerminalBusyPolicy.state(.progress(.pause)), .idle)
        XCTAssertEqual(TerminalBusyPolicy.state(.commandFinished), .idle)
    }

    func testIsBusyMatchesStateForEverySignal() {
        // `isBusy` is a thin wrapper over `state`; pin them so they can't drift.
        let signals: [TerminalBusySignal] = [
            .progress(.indeterminate), .progress(.set(-1)), .progress(.set(0)), .progress(.set(50)),
            .progress(.set(99)), .progress(.set(100)), .progress(.remove), .progress(.error),
            .progress(.pause), .commandFinished
        ]
        for signal in signals {
            XCTAssertEqual(TerminalBusyPolicy.isBusy(signal),
                           TerminalBusyPolicy.state(signal) != .idle,
                           "isBusy and state disagree for \(signal)")
        }
    }
}
