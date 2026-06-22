import XCTest
@testable import Domain

/// Contract tests for the `Preferences` value type. They describe what it promises outward —
/// its defaults, that it round-trips through Codable, that a payload missing keys decodes to
/// defaults (forward/backward compatibility), and that `windowAlpha` is clamped to a safe
/// range. Don't edit a contract test to make an implementation pass — if the contract is
/// wrong, flag it.
final class PreferencesTests: XCTestCase {

    func testDefaultsMatchTheInMemoryStartingState() {
        let p = Preferences.default
        XCTAssertEqual(p.themeKey, "operator")
        XCTAssertEqual(p.terminalHeight, 240)
        XCTAssertEqual(p.selectedConnId, "api-gateway")
        XCTAssertEqual(p.selectedItemId, "482")
        XCTAssertEqual(p.windowAlpha, 1.0)
    }

    func testCodableRoundTripPreservesEveryField() throws {
        let original = Preferences(
            themeKey: "nord",
            terminalHeight: 512,
            selectedConnId: "db-primary",
            selectedItemId: "991",
            windowAlpha: 0.75
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadMissingKeysFallsBackToDefaults() throws {
        // A payload written by an older build that only knew about the theme.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.themeKey, "carbon", "the present key is honored")
        XCTAssertEqual(decoded.terminalHeight, Preferences.default.terminalHeight)
        XCTAssertEqual(decoded.selectedConnId, Preferences.default.selectedConnId)
        XCTAssertEqual(decoded.selectedItemId, Preferences.default.selectedItemId)
        XCTAssertEqual(decoded.windowAlpha, Preferences.default.windowAlpha)
    }

    func testWindowAlphaIsClampedToSafeFloor() {
        XCTAssertEqual(Preferences(windowAlpha: 0.0).windowAlpha, 0.3,
                       "a fully transparent window would be unrecoverable")
        XCTAssertEqual(Preferences(windowAlpha: -5).windowAlpha, 0.3)
    }

    func testWindowAlphaIsClampedToCeiling() {
        XCTAssertEqual(Preferences(windowAlpha: 2.0).windowAlpha, 1.0)
    }

    func testWindowAlphaWithinRangeIsUnchanged() {
        XCTAssertEqual(Preferences(windowAlpha: 0.6).windowAlpha, 0.6)
    }

    func testDecodedOutOfRangeAlphaIsAlsoClamped() throws {
        let json = Data(#"{"windowAlpha":0.0}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.windowAlpha, 0.3, "clamping holds however a Preferences is built")
    }

    func testFollowedOrgsDefaultsToNil() {
        XCTAssertNil(Preferences.default.followedOrgs,
                     "an uncustomized list means 'show every org GitHub returns'")
    }

    func testFollowedOrgsRoundTripsThroughCodable() throws {
        let original = Preferences(followedOrgs: ["acme", "widgets"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.followedOrgs, ["acme", "widgets"])
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutFollowedOrgsFallsBackToNil() throws {
        // A payload written by a build before org-following existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.followedOrgs)
    }
}
