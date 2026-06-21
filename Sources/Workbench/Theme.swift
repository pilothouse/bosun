import AppKit

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
    static func whiteA(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
    static func blackA(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }
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

    static let all: [Theme] = [operatorTheme, carbon, nord, daylight]

    static func named(_ key: String) -> Theme {
        all.first { $0.key == key } ?? operatorTheme
    }

    static let operatorTheme = Theme(
        key: "operator", label: "Operator", note: "Dark · periwinkle",
        swatch: [.hex(0x0d0f13), .hex(0x7c8cff), .hex(0x16181d)],
        win: .hex(0x0d0f13), panel: .hex(0x101318), bar: .hex(0x16181d),
        line: .whiteA(0.06), line2: .whiteA(0.10),
        card: .whiteA(0.03), cardbr: .whiteA(0.07), hover: .whiteA(0.05),
        txt: .hex(0xe6e8ec), txt2: .hex(0xc2c6cd), txt3: .hex(0x8a909a), txt4: .hex(0x5b616b), txt5: .hex(0x454b54),
        accent: .hex(0x7c8cff), accentbg: .hexA(0x7c8cff, 0.10), accentbg2: .hexA(0x7c8cff, 0.14), onacc: .hex(0x0d0f13))

    static let carbon = Theme(
        key: "carbon", label: "Carbon", note: "True black · OLED",
        swatch: [.hex(0x000000), .hex(0x7c8cff), .hex(0x0d0e11)],
        win: .hex(0x000000), panel: .hex(0x08090b), bar: .hex(0x0d0e11),
        line: .whiteA(0.07), line2: .whiteA(0.12),
        card: .whiteA(0.04), cardbr: .whiteA(0.08), hover: .whiteA(0.06),
        txt: .hex(0xf0f1f4), txt2: .hex(0xc8ccd3), txt3: .hex(0x878d98), txt4: .hex(0x5b616b), txt5: .hex(0x42474e),
        accent: .hex(0x7c8cff), accentbg: .hexA(0x7c8cff, 0.12), accentbg2: .hexA(0x7c8cff, 0.18), onacc: .hex(0x000000))

    static let nord = Theme(
        key: "nord", label: "Nord", note: "Cool slate · cyan",
        swatch: [.hex(0x2e3440), .hex(0x88c0d0), .hex(0x3b4252)],
        win: .hex(0x2e3440), panel: .hex(0x2b313c), bar: .hex(0x373f4d),
        line: .whiteA(0.08), line2: .whiteA(0.13),
        card: .whiteA(0.04), cardbr: .whiteA(0.09), hover: .whiteA(0.06),
        txt: .hex(0xeceff4), txt2: .hex(0xd2d9e4), txt3: .hex(0x9aa6b8), txt4: .hex(0x6f7b8e), txt5: .hex(0x586273),
        accent: .hex(0x88c0d0), accentbg: .hexA(0x88c0d0, 0.14), accentbg2: .hexA(0x88c0d0, 0.20), onacc: .hex(0x1b212b))

    static let daylight = Theme(
        key: "light", label: "Daylight", note: "White · indigo",
        swatch: [.hex(0xffffff), .hex(0x4f5bff), .hex(0xedeff2)],
        win: .hex(0xffffff), panel: .hex(0xf6f7f9), bar: .hex(0xedeff2),
        line: .blackA(0.08), line2: .blackA(0.13),
        card: .blackA(0.025), cardbr: .blackA(0.09), hover: .blackA(0.045),
        txt: .hex(0x1b1e23), txt2: .hex(0x3e454f), txt3: .hex(0x5c646f), txt4: .hex(0x8b929c), txt5: .hex(0xabb1b9),
        accent: .hex(0x4f5bff), accentbg: .hexA(0x4f5bff, 0.10), accentbg2: .hexA(0x4f5bff, 0.14), onacc: .hex(0xffffff))
}

/// Status colors are fixed (not theme-dependent), matching the mock's hardcoded values.
enum Status {
    static let green = NSColor.hex(0x3fb950)
    static let yellow = NSColor.hex(0xd29922)
    static let red = NSColor.hex(0xf85149)
    static let purple = NSColor.hex(0xd2a8ff)
    static let dim = NSColor.hex(0x6b7079)
    static let add = NSColor.hex(0x3fb950)
    static let del = NSColor.hex(0xf85149)
}
