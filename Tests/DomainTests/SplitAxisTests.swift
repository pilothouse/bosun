import XCTest
@testable import Domain

/// Contract tests for the `SplitAxis` orientation choice, persisted in `Preferences.splitAxis`.
/// They describe what it promises outward — its default, its stable storage keys, and that it
/// toggles between the two layouts — not how it works inside. The raw values are storage keys,
/// not display labels, so a label change never invalidates a stored value. Mirrors
/// `ItemSortingTests`/`RepoOrderingTests`. Don't edit a contract test to make an implementation
/// pass; if the contract is wrong, flag it.
final class SplitAxisTests: XCTestCase {

    func testDefaultIsVertical() {
        XCTAssertEqual(SplitAxis.default, .vertical,
                       "today's stacked detail-over-terminal layout stays the default")
    }

    func testRawValuesAreStableStorageKeys() {
        XCTAssertEqual(SplitAxis.vertical.rawValue, "vertical")
        XCTAssertEqual(SplitAxis.horizontal.rawValue, "horizontal")
    }

    func testToggledFlipsBothWays() {
        XCTAssertEqual(SplitAxis.vertical.toggled, .horizontal)
        XCTAssertEqual(SplitAxis.horizontal.toggled, .vertical)
    }

    func testCodableRoundTrip() throws {
        for axis in SplitAxis.allCases {
            let data = try JSONEncoder().encode(axis)
            XCTAssertEqual(try JSONDecoder().decode(SplitAxis.self, from: data), axis)
        }
    }

    func testUnknownRawValueIsNilSoCallersCanFallBack() {
        // The App layer maps a stored key back with `SplitAxis(rawValue:) ?? .default`, so an
        // unrecognized key (a future build) must decode to nil rather than crash.
        XCTAssertNil(SplitAxis(rawValue: "diagonal"))
    }

    func testHasExactlyTwoCases() {
        XCTAssertEqual(SplitAxis.allCases, [.vertical, .horizontal])
    }
}
