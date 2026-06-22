import XCTest
@testable import Domain

/// Contract tests for the pure terminal-close rule. They describe what `TerminalClosePolicy`
/// promises outward, not how it works inside. Don't edit a contract test to make an
/// implementation pass — if the contract is wrong, flag it.
final class TerminalClosePolicyTests: XCTestCase {
    func testConfirmsWhenProcessAlive() {
        XCTAssertTrue(TerminalClosePolicy.shouldConfirmClose(processAlive: true))
    }

    func testNoConfirmWhenProcessExited() {
        XCTAssertFalse(TerminalClosePolicy.shouldConfirmClose(processAlive: false))
    }
}
