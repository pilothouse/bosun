import XCTest
@testable import Domain

/// Contract tests for the pure terminal-palette → ghostty-config renderer. They describe the
/// override text `TerminalPalette` promises outward (the keys, their order, and the repeated
/// `palette = i=hex` lines libghostty expects), not how it builds it. Don't edit a contract test
/// to make an implementation pass — if the contract is wrong, flag it.
final class TerminalPaletteTests: XCTestCase {
    /// A palette whose 16 ANSI entries are `000000`…`00000f`, so the index↔line mapping is obvious.
    private func samplePalette() -> TerminalPalette {
        let ansi = (0..<16).map { "00000" + String($0, radix: 16) }
        return TerminalPalette(background: "0a0c0f", foreground: "c2c6cd", cursor: "7c8cff", ansi: ansi)
    }

    func testRendersTheFullOverrideBlockInOrder() {
        let text = samplePalette().ghosttyConfig(fontFamily: "JetBrains Mono", cursorStyle: "block",
                                                 fontSize: 13)
        var expected = """
        background = 0a0c0f
        foreground = c2c6cd
        cursor-color = 7c8cff
        cursor-style = block
        font-family = JetBrains Mono
        font-size = 13.0
        """
        for i in 0..<16 { expected += "\npalette = \(i)=00000" + String(i, radix: 16) }
        XCTAssertEqual(text, expected)
    }

    func testEmitsExactlySixteenPaletteLines() {
        let text = samplePalette().ghosttyConfig(fontFamily: "Menlo", cursorStyle: "bar", fontSize: 13)
        let paletteLines = text.split(separator: "\n").filter { $0.hasPrefix("palette = ") }
        XCTAssertEqual(paletteLines.count, 16)
        XCTAssertEqual(paletteLines.first, "palette = 0=000000")
        XCTAssertEqual(paletteLines.last, "palette = 15=00000f")
    }

    func testFontAndCursorStyleAreParameterized() {
        let text = samplePalette().ghosttyConfig(fontFamily: "Fira Code", cursorStyle: "underline",
                                                 fontSize: 13)
        XCTAssertTrue(text.contains("font-family = Fira Code"))
        XCTAssertTrue(text.contains("cursor-style = underline"))
    }

    func testFontSizeIsRenderedAndRoundedToTwoDecimals() {
        // The App layer feeds base × zoom-scale here, which carries a float tail (13 × 1.2 ≈
        // 15.600000000000001); the renderer must emit a clean `font-size = 15.6`.
        let text = samplePalette().ghosttyConfig(fontFamily: "Menlo", cursorStyle: "block",
                                                 fontSize: 13 * 1.2)
        XCTAssertTrue(text.contains("font-size = 15.6"), "got: \(text)")
    }

    // MARK: - Terminal configuration keys (#67)

    /// The three-argument form (no terminal-config args) emits *only* the original block — the new
    /// keys are opt-in, so an upgrade and the contract above stay byte-identical.
    func testOmitsTerminalConfigKeysWhenNotSupplied() {
        let text = samplePalette().ghosttyConfig(fontFamily: "Menlo", cursorStyle: "block", fontSize: 13)
        XCTAssertFalse(text.contains("cursor-style-blink"))
        XCTAssertFalse(text.contains("window-padding-x"))
        XCTAssertFalse(text.contains("window-padding-y"))
        XCTAssertFalse(text.contains("macos-option-as-alt"))
        XCTAssertFalse(text.contains("desktop-notifications"))
        XCTAssertFalse(text.contains("bell-features"))
    }

    func testEmitsSuppliedTerminalConfigKeys() {
        let text = samplePalette().ghosttyConfig(
            fontFamily: "Menlo", cursorStyle: "bar", fontSize: 13,
            cursorBlink: true, paddingX: 2, paddingY: 4,
            optionAsAlt: false, desktopNotifications: true, systemBell: true)
        XCTAssertTrue(text.contains("cursor-style-blink = true"), "got: \(text)")
        XCTAssertTrue(text.contains("window-padding-x = 2"), "got: \(text)")
        XCTAssertTrue(text.contains("window-padding-y = 4"), "got: \(text)")
        XCTAssertTrue(text.contains("macos-option-as-alt = false"), "got: \(text)")
        XCTAssertTrue(text.contains("desktop-notifications = true"), "got: \(text)")
        XCTAssertTrue(text.contains("bell-features = system"), "got: \(text)")
    }

    /// The bell is a flag set, not a bool: `false` means leave it at ghostty's default (off) by
    /// omitting the key entirely rather than writing `bell-features = false` (which ghostty rejects).
    func testSystemBellOffOmitsTheBellFeaturesKey() {
        let text = samplePalette().ghosttyConfig(
            fontFamily: "Menlo", cursorStyle: "block", fontSize: 13, systemBell: false)
        XCTAssertFalse(text.contains("bell-features"), "got: \(text)")
    }

    func testCursorBlinkRendersFalse() {
        let text = samplePalette().ghosttyConfig(
            fontFamily: "Menlo", cursorStyle: "block", fontSize: 13, cursorBlink: false)
        XCTAssertTrue(text.contains("cursor-style-blink = false"), "got: \(text)")
    }
}
