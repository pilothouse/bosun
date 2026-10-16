import XCTest
@testable import Domain

/// Contract tests for the connection color palette and its tint rule (#102). The raw values are
/// storage keys written to `connections.json` and synced over iCloud, so they are pinned exactly; the
/// tint policy is pinned by the properties every surface relies on (none means no tint, Daylight is
/// lighter, fills stay subtle enough to keep text readable) rather than by its exact numbers. Don't edit
/// a contract test to make an implementation pass — if the contract is wrong, flag it.
final class ConnectionColorTests: XCTestCase {
    private let fills: [ConnectionColorSurface] = [.railRow, .tab, .tileHeader, .terminalBackground]
    private let allSurfaces = ConnectionColorSurface.allCases

    func testRawValuesAreStableStorageKeys() {
        XCTAssertEqual(ConnectionColor.allCases.map(\.rawValue),
                       ["red", "orange", "yellow", "green", "teal", "blue", "purple", "gray"])
    }

    func testNoColorMeansNoTintOnAnySurface() {
        for surface in allSurfaces {
            XCTAssertEqual(ConnectionColorPolicy.opacity(of: nil, on: surface, lightTheme: false), 0,
                           "dark theme, \(surface)")
            XCTAssertEqual(ConnectionColorPolicy.opacity(of: nil, on: surface, lightTheme: true), 0,
                           "light theme, \(surface)")
        }
    }

    func testEveryColorTintsEverySurface() {
        for color in ConnectionColor.allCases {
            for surface in allSurfaces {
                XCTAssertGreaterThan(ConnectionColorPolicy.opacity(of: color, on: surface, lightTheme: false), 0,
                                     "\(color) on \(surface)")
                XCTAssertGreaterThan(ConnectionColorPolicy.opacity(of: color, on: surface, lightTheme: true), 0,
                                     "\(color) on \(surface), light")
            }
        }
    }

    func testLightThemeGetsLighterTintsOnEverySurface() {
        for surface in allSurfaces {
            let dark = ConnectionColorPolicy.opacity(of: .blue, on: surface, lightTheme: false)
            let light = ConnectionColorPolicy.opacity(of: .blue, on: surface, lightTheme: true)
            XCTAssertLessThan(light, dark, "\(surface)")
        }
    }

    func testFillsStaySubtleSoTextStaysReadable() {
        for surface in fills {
            for light in [false, true] {
                XCTAssertLessThanOrEqual(ConnectionColorPolicy.opacity(of: .red, on: surface, lightTheme: light), 0.2,
                                         "\(surface), light: \(light)")
            }
        }
    }

    func testTerminalBackgroundIsTheFaintestFill() {
        for light in [false, true] {
            let terminal = ConnectionColorPolicy.opacity(of: .green, on: .terminalBackground, lightTheme: light)
            for surface in fills where surface != .terminalBackground {
                XCTAssertLessThan(terminal,
                                  ConnectionColorPolicy.opacity(of: .green, on: surface, lightTheme: light),
                                  "\(surface), light: \(light)")
            }
        }
    }
}
