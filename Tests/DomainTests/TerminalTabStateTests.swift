import XCTest
@testable import Domain

/// Contract tests for `TerminalTabState` — the persisted shape of one open terminal tab, used to
/// reopen tabs on relaunch. It promises a lossless Codable round-trip for both a local shell and a
/// connection (keyed by connection id). Don't edit a contract test to make an implementation pass.
final class TerminalTabStateTests: XCTestCase {

    func testLocalTabRoundTripsThroughCodable() throws {
        let original = TerminalTabState(kind: .local, title: "zsh")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .local)
    }

    func testConnectionTabRoundTripsThroughCodable() throws {
        let id = "941E6AA4-CC93-4887-B6B9-503CAA9639E5"
        let original = TerminalTabState(kind: .connection(id: id), title: "Forge - API")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTabState.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .connection(id: id))
    }

    func testAListOfTabsRoundTrips() throws {
        let tabs = [
            TerminalTabState(kind: .connection(id: "abc"), title: "Forge - API"),
            TerminalTabState(kind: .local, title: "zsh"),
        ]

        let data = try JSONEncoder().encode(tabs)
        let decoded = try JSONDecoder().decode([TerminalTabState].self, from: data)

        XCTAssertEqual(decoded, tabs)
    }
}
