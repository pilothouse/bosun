import XCTest
@testable import Domain

/// Contract tests for the pure device-flow timing rules (RFC 8628). They describe what
/// `DeviceFlowPolicy` promises outward, not how it works inside. Don't edit a contract test to
/// make an implementation pass — if the contract is wrong, flag it.
final class DeviceFlowPolicyTests: XCTestCase {
    func testEffectiveIntervalFloorsToFive() {
        XCTAssertEqual(DeviceFlowPolicy.effectiveInterval(0), 5)
        XCTAssertEqual(DeviceFlowPolicy.effectiveInterval(3), 5)
    }

    func testEffectiveIntervalKeepsLargerServerValue() {
        XCTAssertEqual(DeviceFlowPolicy.effectiveInterval(10), 10)
    }

    func testSlowDownAddsFiveSeconds() {
        XCTAssertEqual(DeviceFlowPolicy.nextInterval(current: 5), 10)
        XCTAssertEqual(DeviceFlowPolicy.nextInterval(current: 10), 15)
    }

    func testHasBudgetWhileWithinExpiry() {
        XCTAssertTrue(DeviceFlowPolicy.hasBudget(elapsedSeconds: 100, expiresIn: 900))
    }

    func testNoBudgetAtOrPastExpiry() {
        XCTAssertFalse(DeviceFlowPolicy.hasBudget(elapsedSeconds: 900, expiresIn: 900))
        XCTAssertFalse(DeviceFlowPolicy.hasBudget(elapsedSeconds: 901, expiresIn: 900))
    }
}
