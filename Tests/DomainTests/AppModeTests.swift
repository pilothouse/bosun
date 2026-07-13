import XCTest
@testable import Domain

/// Contract tests for the pure launch-mode rule. `AppMode.resolve` is the single place that maps
/// the process environment onto one of the app's mutually-exclusive run modes, so every scattered
/// `BOSUN_*` env read routes through it. These describe what it promises outward — which flag wins,
/// what a bare environment means, that only the exact string "1" counts — not how it works inside.
/// Don't edit a contract test to make an implementation pass; if the contract is wrong, flag it.
final class AppModeTests: XCTestCase {
    func testEmptyEnvironmentIsNormal() {
        XCTAssertEqual(AppMode.resolve(environment: [:]), .normal)
    }

    func testUITestFlagSelectsUITest() {
        XCTAssertEqual(AppMode.resolve(environment: ["BOSUN_UI_TEST": "1"]), .uiTest)
    }

    func testPerfSeedFlagSelectsPerfSeed() {
        XCTAssertEqual(AppMode.resolve(environment: ["BOSUN_PERF_SEED": "1"]), .perfSeed)
    }

    func testUITestWinsWhenBothSet() {
        // The two offline modes are mutually exclusive; UI-test is the newer, canonical one, so it
        // takes precedence over the perf seam when a caller sets both.
        let env = ["BOSUN_UI_TEST": "1", "BOSUN_PERF_SEED": "1"]
        XCTAssertEqual(AppMode.resolve(environment: env), .uiTest)
    }

    func testOnlyTheExactStringOneEnables() {
        // A present-but-not-"1" value (empty, "0", "true", "yes") must not trip a mode — the perf
        // script and CI both pass "1", and a stray export shouldn't silently fake the app's data.
        for value in ["", "0", "true", "yes", "TRUE", " 1", "1 "] {
            XCTAssertEqual(AppMode.resolve(environment: ["BOSUN_UI_TEST": value]), .normal,
                           "BOSUN_UI_TEST=‘\(value)’ should stay normal")
            XCTAssertEqual(AppMode.resolve(environment: ["BOSUN_PERF_SEED": value]), .normal,
                           "BOSUN_PERF_SEED=‘\(value)’ should stay normal")
        }
    }

    func testUnrelatedFlagsAreIgnored() {
        // BOSUN_API_SMOKE is a live-probe boolean, orthogonal to the offline modes — it must not
        // change the resolved mode.
        let env = ["BOSUN_API_SMOKE": "1", "BOSUN_GITHUB_TOKEN": "ghp_x"]
        XCTAssertEqual(AppMode.resolve(environment: env), .normal)
    }
}
