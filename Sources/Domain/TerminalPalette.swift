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
    /// after the user's default files so these win. `fontSize` (points) is the app-wide zoom level
    /// applied to the terminal so it scales in lockstep with the UI; rounded to two decimals so the
    /// emitted config text is stable (a clean `font-size = 15.6`, not a long float tail).
    ///
    /// The user-configurable terminal options (#67) are opt-in trailing parameters: each writes a
    /// line only when supplied (non-`nil`), so the three-argument form stays byte-identical and a
    /// `nil` simply leaves ghostty's own default in place. `systemBell` is a flag set, not a bool —
    /// `true` emits `bell-features = system`, `false` omits the key (writing `= false` is rejected).
    public func ghosttyConfig(fontFamily: String,
                              cursorStyle: String,
                              fontSize: Double,
                              cursorBlink: Bool? = nil,
                              paddingX: Int? = nil,
                              paddingY: Int? = nil,
                              optionAsAlt: Bool? = nil,
                              desktopNotifications: Bool? = nil,
                              systemBell: Bool = false) -> String {
        var lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor)",
            "cursor-style = \(cursorStyle)",
            "font-family = \(fontFamily)",
            "font-size = \((fontSize * 100).rounded() / 100)",
        ]
        if let cursorBlink { lines.append("cursor-style-blink = \(cursorBlink)") }
        if let paddingX { lines.append("window-padding-x = \(paddingX)") }
        if let paddingY { lines.append("window-padding-y = \(paddingY)") }
        if let optionAsAlt { lines.append("macos-option-as-alt = \(optionAsAlt)") }
        if let desktopNotifications { lines.append("desktop-notifications = \(desktopNotifications)") }
        if systemBell { lines.append("bell-features = system") }
        for (index, hex) in ansi.enumerated() {
            lines.append("palette = \(index)=\(hex)")
        }
        return lines.joined(separator: "\n")
    }

    /// This palette with `background` mixed toward `hex` (`rrggbb` or `#rrggbb`) by `opacity` — the
    /// faint per-connection terminal tint (#102). Each sRGB channel is `bg·(1−a) + tint·a`, rounded, so
    /// the App layer can paint the active tab with the exact color the surface renders. `opacity` is
    /// clamped to `0…1`; an unparsable hex (or either side not six hex digits) leaves the palette
    /// unchanged, so a bad value degrades to "no tint" rather than a broken terminal.
    public func tintingBackground(with hex: String, opacity: Double) -> TerminalPalette {
        let alpha = min(1, max(0, opacity))
        guard alpha > 0, let base = Self.channels(background), let tint = Self.channels(hex) else { return self }
        let mixed = zip(base, tint).map { pair in
            Int((Double(pair.0) * (1 - alpha) + Double(pair.1) * alpha).rounded())
        }
        let blended = mixed.map { String(format: "%02x", $0) }.joined()
        return TerminalPalette(background: blended, foreground: foreground, cursor: cursor, ansi: ansi)
    }

    /// The three 0…255 channels of a `rrggbb` / `#rrggbb` string, or `nil` when it isn't six hex digits.
    private static func channels(_ hex: String) -> [Int]? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff]
    }
}
