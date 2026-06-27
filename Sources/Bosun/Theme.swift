import AppKit
import Domain

extension NSColor {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    static func hexA(_ v: UInt32, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    /// Parse a `"rrggbb"` / `"#rrggbb"` hex string (e.g. GitHub's `Label.color`) into a color, or
    /// nil if it isn't six hex digits. Complements `hex(_ v: UInt32)`.
    static func hex(string: String) -> NSColor? {
        let s = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return .hex(v)
    }

    static func whiteA(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
    static func blackA(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

    /// `rrggbb` for a libghostty config line. Resolves through sRGB (the space `.hex` builds in)
    /// and drops alpha — terminal palette entries are opaque.
    var ghosttyHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// A theme palette mirrored from the design's THEMES object.
struct Theme {
    let key: String
    let label: String
    let note: String
    let swatch: [NSColor]   // s0, s1, s2

    let win, panel, bar, line, line2, card, cardbr, hover: NSColor
    let txt, txt2, txt3, txt4, txt5: NSColor
    let accent, accentbg, accentbg2, onacc: NSColor

    // Terminal (libghostty) colors: the surface bg/fg/cursor plus the 16 ANSI colors. Kept on the
    // theme so the docked terminal and its chrome track the app theme (issue #9).
    let termBg, termFg, termCursor: NSColor
    let ansi: [NSColor]   // 16 entries, ANSI 0…15

    /// The pure value the App layer hands to libghostty. NSColor→hex conversion lives here (AppKit);
    /// the config-text rendering lives in Domain's `TerminalPalette`.
    var terminalPalette: TerminalPalette {
        TerminalPalette(background: termBg.ghosttyHex,
                        foreground: termFg.ghosttyHex,
                        cursor: termCursor.ghosttyHex,
                        ansi: ansi.map(\.ghosttyHex))
    }

    static let all: [Theme] = [operatorTheme, carbon, nord, daylight]

    static func named(_ key: String) -> Theme {
        all.first { $0.key == key } ?? operatorTheme
    }

    /// Dark ANSI set shared by Operator + Carbon, harmonized with the periwinkle accent and
    /// reusing the app's `Status` hues (red/green/yellow/purple) where they fit.
    private static let darkANSI: [NSColor] = [
        .hex(0x16181d), .hex(0xf85149), .hex(0x3fb950), .hex(0xd29922),
        .hex(0x7c8cff), .hex(0xd2a8ff), .hex(0x56b6c2), .hex(0xc2c6cd),
        .hex(0x5b616b), .hex(0xff6b63), .hex(0x56d364), .hex(0xe3b341),
        .hex(0x9aa6ff), .hex(0xe0b8ff), .hex(0x6cd0db), .hex(0xe6e8ec)]

    /// Nord's official 16-color ANSI palette.
    private static let nordANSI: [NSColor] = [
        .hex(0x3b4252), .hex(0xbf616a), .hex(0xa3be8c), .hex(0xebcb8b),
        .hex(0x81a1c1), .hex(0xb48ead), .hex(0x88c0d0), .hex(0xe5e9f0),
        .hex(0x4c566a), .hex(0xbf616a), .hex(0xa3be8c), .hex(0xebcb8b),
        .hex(0x81a1c1), .hex(0xb48ead), .hex(0x8fbcbb), .hex(0xeceff4)]

    /// Light ANSI set for Daylight: darker, saturated colors so output stays legible on white
    /// (the "white" slots 7/15 become grays rather than disappearing into the background).
    private static let lightANSI: [NSColor] = [
        .hex(0x1b1e23), .hex(0xd11d2b), .hex(0x1a7f37), .hex(0x9a6700),
        .hex(0x4f5bff), .hex(0x8250df), .hex(0x1b7c83), .hex(0x5c646f),
        .hex(0x8b929c), .hex(0xcf222e), .hex(0x1a7f37), .hex(0x7d4e00),
        .hex(0x4f5bff), .hex(0x8250df), .hex(0x137c83), .hex(0x1b1e23)]

    static let operatorTheme = Theme(
        key: "operator", label: "Operator", note: "Dark · periwinkle",
        swatch: [.hex(0x0d0f13), .hex(0x7c8cff), .hex(0x16181d)],
        win: .hex(0x0d0f13), panel: .hex(0x101318), bar: .hex(0x16181d),
        line: .whiteA(0.06), line2: .whiteA(0.10),
        card: .whiteA(0.03), cardbr: .whiteA(0.07), hover: .whiteA(0.05),
        txt: .hex(0xe6e8ec), txt2: .hex(0xc2c6cd), txt3: .hex(0x8a909a), txt4: .hex(0x5b616b), txt5: .hex(0x454b54),
        accent: .hex(0x7c8cff), accentbg: .hexA(0x7c8cff, 0.10), accentbg2: .hexA(0x7c8cff, 0.14), onacc: .hex(0x0d0f13),
        termBg: .hex(0x0a0c0f), termFg: .hex(0xc2c6cd), termCursor: .hex(0x7c8cff), ansi: darkANSI)

    static let carbon = Theme(
        key: "carbon", label: "Carbon", note: "True black · OLED",
        swatch: [.hex(0x000000), .hex(0x7c8cff), .hex(0x0d0e11)],
        win: .hex(0x000000), panel: .hex(0x08090b), bar: .hex(0x0d0e11),
        line: .whiteA(0.07), line2: .whiteA(0.12),
        card: .whiteA(0.04), cardbr: .whiteA(0.08), hover: .whiteA(0.06),
        txt: .hex(0xf0f1f4), txt2: .hex(0xc8ccd3), txt3: .hex(0x878d98), txt4: .hex(0x5b616b), txt5: .hex(0x42474e),
        accent: .hex(0x7c8cff), accentbg: .hexA(0x7c8cff, 0.12), accentbg2: .hexA(0x7c8cff, 0.18), onacc: .hex(0x000000),
        termBg: .hex(0x000000), termFg: .hex(0xc8ccd3), termCursor: .hex(0x7c8cff), ansi: darkANSI)

    static let nord = Theme(
        key: "nord", label: "Nord", note: "Cool slate · cyan",
        swatch: [.hex(0x2e3440), .hex(0x88c0d0), .hex(0x3b4252)],
        win: .hex(0x2e3440), panel: .hex(0x2b313c), bar: .hex(0x373f4d),
        line: .whiteA(0.08), line2: .whiteA(0.13),
        card: .whiteA(0.04), cardbr: .whiteA(0.09), hover: .whiteA(0.06),
        txt: .hex(0xeceff4), txt2: .hex(0xd2d9e4), txt3: .hex(0x9aa6b8), txt4: .hex(0x6f7b8e), txt5: .hex(0x586273),
        accent: .hex(0x88c0d0), accentbg: .hexA(0x88c0d0, 0.14), accentbg2: .hexA(0x88c0d0, 0.20), onacc: .hex(0x1b212b),
        termBg: .hex(0x2e3440), termFg: .hex(0xd8dee9), termCursor: .hex(0x88c0d0), ansi: nordANSI)

    static let daylight = Theme(
        key: "light", label: "Daylight", note: "White · indigo",
        swatch: [.hex(0xffffff), .hex(0x4f5bff), .hex(0xedeff2)],
        win: .hex(0xffffff), panel: .hex(0xf6f7f9), bar: .hex(0xedeff2),
        line: .blackA(0.08), line2: .blackA(0.13),
        card: .blackA(0.025), cardbr: .blackA(0.09), hover: .blackA(0.045),
        txt: .hex(0x1b1e23), txt2: .hex(0x3e454f), txt3: .hex(0x5c646f), txt4: .hex(0x8b929c), txt5: .hex(0xabb1b9),
        accent: .hex(0x4f5bff), accentbg: .hexA(0x4f5bff, 0.10), accentbg2: .hexA(0x4f5bff, 0.14), onacc: .hex(0xffffff),
        termBg: .hex(0xffffff), termFg: .hex(0x1b1e23), termCursor: .hex(0x4f5bff), ansi: lightANSI)
}

/// Status colors are fixed (not theme-dependent), matching the mock's hardcoded values.
enum Status {
    static let green = NSColor.hex(0x3fb950)
    static let yellow = NSColor.hex(0xd29922)
    static let red = NSColor.hex(0xf85149)
    static let purple = NSColor.hex(0xd2a8ff)
    static let blue = NSColor.hex(0x58a6ff)
    static let dim = NSColor.hex(0x6b7079)
    static let add = NSColor.hex(0x3fb950)
    static let del = NSColor.hex(0xf85149)
}
