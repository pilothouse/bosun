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
        let text = samplePalette().ghosttyConfig(fontFamily: "JetBrains Mono", cursorStyle: "block")
        var expected = """
        background = 0a0c0f
        foreground = c2c6cd
        cursor-color = 7c8cff
        cursor-style = block
        font-family = JetBrains Mono
        """
        for i in 0..<16 { expected += "\npalette = \(i)=00000" + String(i, radix: 16) }
        XCTAssertEqual(text, expected)
    }

    func testEmitsExactlySixteenPaletteLines() {
        let text = samplePalette().ghosttyConfig(fontFamily: "Menlo", cursorStyle: "bar")
        let paletteLines = text.split(separator: "\n").filter { $0.hasPrefix("palette = ") }
        XCTAssertEqual(paletteLines.count, 16)
        XCTAssertEqual(paletteLines.first, "palette = 0=000000")
        XCTAssertEqual(paletteLines.last, "palette = 15=00000f")
    }

    func testFontAndCursorStyleAreParameterized() {
        let text = samplePalette().ghosttyConfig(fontFamily: "Fira Code", cursorStyle: "underline")
        XCTAssertTrue(text.contains("font-family = Fira Code"))
        XCTAssertTrue(text.contains("cursor-style = underline"))
    }
}
