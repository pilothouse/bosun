/// The terminal color scheme, as hex strings (`rrggbb`, no leading `#`), ready to render into a
/// libghostty config override block. Plain data with no AppKit — the App layer maps the active
/// `Theme`'s `NSColor`s onto this, and `ghosttyConfig` turns it into the text libghostty parses.
/// Pure, like `SSHCommand`: the same palette renders identically whether it's applied on launch,
/// on a theme switch, or in a test.
public struct TerminalPalette: Equatable, Sendable {
    public let background: String
    public let foreground: String
    public let cursor: String
    /// The 16 ANSI colors, indices 0…15 (8 normal, then 8 bright).
    public let ansi: [String]

    public init(background: String, foreground: String, cursor: String, ansi: [String]) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }

    /// The libghostty config override block: the surface colors first, then one repeated
    /// `palette = <index>=<hex>` line per ANSI entry (the form ghostty's parser expects). Loaded
    /// after the user's default files so these win.
    public func ghosttyConfig(fontFamily: String, cursorStyle: String) -> String {
        var lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor)",
            "cursor-style = \(cursorStyle)",
            "font-family = \(fontFamily)",
        ]
        for (index, hex) in ansi.enumerated() {
            lines.append("palette = \(index)=\(hex)")
        }
        return lines.joined(separator: "\n")
    }
}
