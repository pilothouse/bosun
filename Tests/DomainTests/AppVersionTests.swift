import XCTest
@testable import Domain

/// Contract tests for the pure version-presentation rule. They describe what `AppVersion` promises
/// outward — keep a real Info.plist version, fall back to an explicit "dev" marker when there's none
/// (a bare `swift build` with no Info.plist), and drop a build that says nothing (missing, placeholder,
/// or a repeat of the short version) — not how it works inside. Don't edit a contract test to make an
/// implementation pass — if the contract is wrong, flag it.
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

    func testBuildIdenticalToShortVersionIsDropped() {
        // A shipped release has CFBundleVersion == CFBundleShortVersionString: release.yml stamps both
        // from the tag, and it must, because Sparkle's default comparator checks the appcast's
        // sparkle:version against CFBundleVersion. Rendering that as "1.0.0 (1.0.0)" is pure noise, so
        // the duplicate is dropped like the "0" placeholder. Whitespace is trimmed before comparing.
        for build in ["1.0.0", "  1.0.0  "] {
            let info = AppVersion.info(shortVersion: "1.0.0", build: build)
            XCTAssertEqual(info.shortVersion, "1.0.0")
            XCTAssertNil(info.build, "‘\(build)’ repeats the short version, so it carries no information")
            XCTAssertFalse(info.isDev)
            XCTAssertEqual(info.displayString, "1.0.0")
        }
    }

    func testBuildDifferingFromShortVersionIsKept() {
        // Only an exact match is dropped — a build that merely looks similar is still real information.
        let info = AppVersion.info(shortVersion: "1.0.0", build: "1.0.0.1")
        XCTAssertEqual(info.build, "1.0.0.1")
        XCTAssertEqual(info.displayString, "1.0.0 (1.0.0.1)")
    }

    func testRealBuildIsKeptInDisplayString() {
        let info = AppVersion.info(shortVersion: "1.2.3", build: "100")
        XCTAssertEqual(info.build, "100")
        XCTAssertEqual(info.displayString, "1.2.3 (100)")
    }
}
