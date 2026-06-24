import XCTest
@testable import Domain

/// Contract tests for the pure terminal-title rule. They describe what `TerminalTitlePolicy`
/// promises outward — when a server/OSC-reported title may replace a tab's label — not how it
/// works inside. Don't edit a contract test to make an implementation pass; if the contract is
/// wrong, flag it.
final class TerminalTitlePolicyTests: XCTestCase {
    func testLockedTabKeepsItsLabel() {
        // The core of #29: a named connection ignores the server title.
        XCTAssertNil(TerminalTitlePolicy.resolved(incoming: "user@host: ~", current: "Forge - API",
                                                  locked: true))
    }

    func testUnlockedTabFollowsANewTitle() {
        XCTAssertEqual(TerminalTitlePolicy.resolved(incoming: "user@host: ~", current: "zsh",
                                                    locked: false), "user@host: ~")
    }

    func testUnlockedTitleIsTrimmed() {
        XCTAssertEqual(TerminalTitlePolicy.resolved(incoming: "  dev  \n", current: "zsh",
                                                    locked: false), "dev")
    }

    func testUnlockedEmptyOrWhitespaceTitleIsIgnored() {
        XCTAssertNil(TerminalTitlePolicy.resolved(incoming: "", current: "zsh", locked: false))
        XCTAssertNil(TerminalTitlePolicy.resolved(incoming: "   \n\t", current: "zsh", locked: false))
    }

    func testUnlockedUnchangedTitleIsIgnored() {
        XCTAssertNil(TerminalTitlePolicy.resolved(incoming: "zsh", current: "zsh", locked: false))
        // Equality is checked after trimming.
        XCTAssertNil(TerminalTitlePolicy.resolved(incoming: "  zsh  ", current: "zsh", locked: false))
    }

    func testLockedEmptyTitleIsIgnored() {
        XCTAssertNil(TerminalTitlePolicy.resolved(incoming: "", current: "Forge - API", locked: true))
    }
}
