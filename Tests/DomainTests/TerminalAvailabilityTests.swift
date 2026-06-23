import XCTest
@testable import Domain

/// Contract tests for the terminal-subsystem availability fact. They describe what
/// `TerminalAvailability` promises outward — whether the terminal came up and, if not, which
/// startup stage failed — not how the App layer renders it. User-facing copy is presentation and
/// lives in Bosun (the App layer), so it is deliberately NOT asserted here: wording can change without
/// touching this contract.
final class TerminalAvailabilityTests: XCTestCase {
    func testReadyIsReady() {
        XCTAssertTrue(TerminalAvailability.ready.isReady)
    }

    func testEveryUnavailableStageIsNotReady() {
        for stage in TerminalStartupStage.allCases {
            XCTAssertFalse(TerminalAvailability.unavailable(stage).isReady,
                           "unavailable(\(stage)) must not be ready")
        }
    }

    func testDistinctStagesAreNotEqual() {
        XCTAssertNotEqual(TerminalAvailability.unavailable(.runtimeInit),
                          TerminalAvailability.unavailable(.configuration))
        XCTAssertNotEqual(TerminalAvailability.unavailable(.configuration),
                          TerminalAvailability.unavailable(.application))
        XCTAssertNotEqual(TerminalAvailability.unavailable(.runtimeInit),
                          TerminalAvailability.ready)
    }

    func testSameStageIsEqual() {
        XCTAssertEqual(TerminalAvailability.unavailable(.application),
                       TerminalAvailability.unavailable(.application))
    }
}
