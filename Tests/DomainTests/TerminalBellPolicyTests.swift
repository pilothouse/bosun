import XCTest
@testable import Domain

/// Contract tests for the pure background-bell rule. They describe what `TerminalBellPolicy`
/// promises outward — when a tab that rings/notifies should raise an activity badge — not how it
/// works inside. Don't edit a contract test to make an implementation pass; if the contract is
/// wrong, flag it.
final class TerminalBellPolicyTests: XCTestCase {
    func testInactiveTabFlagsWhenEnabled() {
        // The core of #74: a background tab that rings wants attention.
        XCTAssertTrue(TerminalBellPolicy.shouldFlag(isActiveTab: false, enabled: true))
    }

    func testActiveTabNeverFlags() {
        // The active surface is already on screen — a badge there is only visible while the app is
        // backgrounded and must vanish on return, so a bell on it is a no-op even when enabled.
        XCTAssertFalse(TerminalBellPolicy.shouldFlag(isActiveTab: true, enabled: true))
    }

    func testDisabledNeverFlags() {
        XCTAssertFalse(TerminalBellPolicy.shouldFlag(isActiveTab: false, enabled: false))
        XCTAssertFalse(TerminalBellPolicy.shouldFlag(isActiveTab: true, enabled: false))
    }
}
