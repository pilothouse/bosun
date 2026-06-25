import XCTest
@testable import Domain

/// Contract tests for the pure version-presentation rule. They describe what `AppVersion` promises
/// outward — keep a real Info.plist version, fall back to an explicit "dev" marker when there's none
/// (a bare `swift build` with no Info.plist), and drop a missing or placeholder build — not how it
/// works inside. Don't edit a contract test to make an implementation pass — if the contract is
/// wrong, flag it.
final class AppVersionTests: XCTestCase {
    func testPackagedValuesAreKept() {
        let info = AppVersion.info(shortVersion: "0.1.0", build: "45")
        XCTAssertEqual(info.shortVersion, "0.1.0")
        XCTAssertEqual(info.build, "45")
        XCTAssertFalse(info.isDev)
        XCTAssertEqual(info.displayString, "0.1.0 (45)")
    }

    func testMissingShortVersionFallsBackToDev() {
        let info = AppVersion.info(shortVersion: nil, build: nil)
        XCTAssertEqual(info.shortVersion, AppVersion.devMarker)
        XCTAssertNil(info.build)
        XCTAssertTrue(info.isDev)
        XCTAssertEqual(info.displayString, "dev")
    }

    func testBlankShortVersionIsTreatedAsDev() {
        // An empty or whitespace-only Info.plist value is as good as absent.
        for blank in ["", "   ", "\n"] {
            let info = AppVersion.info(shortVersion: blank, build: "45")
            XCTAssertEqual(info.shortVersion, AppVersion.devMarker, "‘\(blank)’ should be dev")
            XCTAssertTrue(info.isDev)
            // A dev build never advertises a build number, even if one was passed.
            XCTAssertNil(info.build)
            XCTAssertEqual(info.displayString, "dev")
        }
    }

    func testPlaceholderOrMissingBuildIsDropped() {
        // "0" is the package-app.sh default placeholder — not a real build, so it's omitted.
        for noBuild in ["0", "", "   ", nil] {
            let info = AppVersion.info(shortVersion: "0.1.0", build: noBuild)
            XCTAssertEqual(info.shortVersion, "0.1.0")
            XCTAssertNil(info.build)
            XCTAssertFalse(info.isDev)
            XCTAssertEqual(info.displayString, "0.1.0")
        }
    }

    func testRealBuildIsKeptInDisplayString() {
        let info = AppVersion.info(shortVersion: "1.2.3", build: "100")
        XCTAssertEqual(info.build, "100")
        XCTAssertEqual(info.displayString, "1.2.3 (100)")
    }
}
