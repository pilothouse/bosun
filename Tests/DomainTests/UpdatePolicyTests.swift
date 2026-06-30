import XCTest
@testable import Domain

/// Contract tests for the pure in-app-update rule. They describe what `UpdatePolicy` promises
/// outward — offer Sparkle updates to a normally-distributed build, never to a Mac App Store build
/// (self-updating code is forbidden there) — not how it works inside. The filesystem receipt check
/// lives in the app layer; this owns only the decision. Don't edit a contract test to make an
/// implementation pass — if the contract is wrong, flag it.
final class UpdatePolicyTests: XCTestCase {
    func testNormalBuildSupportsInAppUpdates() {
        XCTAssertTrue(UpdatePolicy.inAppUpdatesSupported(isAppStoreBuild: false))
    }

    func testAppStoreBuildDoesNotSupportInAppUpdates() {
        XCTAssertFalse(UpdatePolicy.inAppUpdatesSupported(isAppStoreBuild: true))
    }
}
