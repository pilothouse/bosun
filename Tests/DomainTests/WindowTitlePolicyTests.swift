import XCTest
@testable import Domain

/// Contract tests for the pure window-title rule. They describe what `WindowTitlePolicy` promises
/// outward — the macOS window title tracks the active console tab (#73) — not how it works inside.
/// Don't edit a contract test to make an implementation pass; if the contract is wrong, flag it.
final class WindowTitlePolicyTests: XCTestCase {
    func testTitleIsTheActiveConsole() {
        // A connection console is locked to its connection name, so this is also the connection.
        XCTAssertEqual(WindowTitlePolicy.title(console: "ghostty"), "ghostty")
    }

    func testConsoleIsTrimmed() {
        XCTAssertEqual(WindowTitlePolicy.title(console: "  …/bosun \n"), "…/bosun")
    }

    func testNilConsoleUsesFallback() {
        XCTAssertEqual(WindowTitlePolicy.title(console: nil), "Bosun")
    }

    func testEmptyOrWhitespaceConsoleUsesFallback() {
        XCTAssertEqual(WindowTitlePolicy.title(console: ""), "Bosun")
        XCTAssertEqual(WindowTitlePolicy.title(console: "   \n\t"), "Bosun")
    }

    func testCustomFallbackIsHonoured() {
        XCTAssertEqual(WindowTitlePolicy.title(console: nil, fallback: "—"), "—")
    }
}
