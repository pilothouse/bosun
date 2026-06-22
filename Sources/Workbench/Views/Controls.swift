import AppKit

/// A flipped container so manual frames lay out top-to-bottom.
class FlippedView: NSView { override var isFlipped: Bool { true } }

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}
func sys(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

/// The width an `NSTextField` needs to render `text` in `font` without truncating.
/// `intrinsicContentSize.width` is the bare glyph-run width and omits the cell's
/// ~4px horizontal inset, so a frame sized to it clips the trailing glyph(s) (AppKit
/// even drops extra characters to make room for the "…"). Add the inset + 1px slack.
func fitW(_ text: String, _ font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width) + 5
}
/// Same, measured from a label's own string and font.
func fitW(_ l: NSTextField) -> CGFloat { fitW(l.stringValue, l.font ?? sys(13)) }

/// A single-line glyph centered on both axes within a box of `size`. A plain
/// `NSTextField` top-aligns its text, so a small glyph in a taller box sits high; we
/// center the line box and nudge down by half the descender (which the line box reserves
/// but glyphs like ✓ / ● / ○ don't occupy) so the visible mark optically centers.
func centeredGlyph(_ text: String, _ font: NSFont, _ color: NSColor, in size: CGSize) -> NSTextField {
    let l = label(text, font, color, align: .center)
    l.sizeToFit()
    let lh = l.frame.height
    let y = (size.height - lh) / 2 - 1
    l.frame = NSRect(x: 0, y: y, width: size.width, height: lh)
    return l
}

func label(_ text: String, _ font: NSFont, _ color: NSColor,
           align: NSTextAlignment = .left, lines: Int = 1) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.alignment = align
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    l.maximumNumberOfLines = lines
    l.cell?.truncatesLastVisibleLine = true
    return l
}

/// Layer-backed view with solid background, rounded corners, optional border.
final class BoxView: FlippedView {
    init(bg: NSColor? = nil, radius: CGFloat = 0, border: NSColor? = nil, borderWidth: CGFloat = 1) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = bg?.cgColor
        layer?.cornerRadius = radius
        if let border {
            layer?.borderColor = border.cgColor
            layer?.borderWidth = borderWidth
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func style(bg: NSColor? = nil, border: NSColor? = nil) {
        if let bg { layer?.backgroundColor = bg.cgColor }
        if let border { layer?.borderColor = border.cgColor }
    }
}

/// A clickable row that highlights on hover and runs a closure on click.
final class ClickRow: FlippedView {
    var onClick: (() -> Void)?
    var hoverColor: NSColor?
    private var baseColor: CGColor?
    private var tracking: NSTrackingArea?

    init(bg: NSColor? = nil, radius: CGFloat = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        baseColor = bg?.cgColor
        layer?.backgroundColor = baseColor
        layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }

    func setBase(_ c: NSColor?) {
        baseColor = c?.cgColor
        layer?.backgroundColor = baseColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { if let h = hoverColor { layer?.backgroundColor = h.cgColor } }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = baseColor }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A solid colored dot / rounded square.
final class Dot: NSView {
    init(_ color: NSColor, _ diameter: CGFloat, radius: CGFloat? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius ?? diameter / 2
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An indeterminate spinning indicator, already animating and sized to `size`. The caller
/// positions it and adds it to the view being (re)built; like `DeviceFlowSheet.addSpinner`
/// it needs no explicit stop — the next `layout()` removes it from the window, halting the timer.
func makeSpinner(size: CGFloat = 20) -> NSProgressIndicator {
    let s = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: size, height: size))
    s.style = .spinning
    s.controlSize = size <= 14 ? .small : .regular
    s.isIndeterminate = true
    s.startAnimation(nil)
    return s
}

/// A small badge: text inside a rounded, tinted, bordered pill.
func badge(_ text: String, fg: NSColor, bg: NSColor? = nil, border: NSColor? = nil, mono monospaced: Bool = true) -> BoxView {
    let b = BoxView(bg: bg, radius: 5, border: border)
    let f = monospaced ? mono(10.5) : sys(10.5, .semibold)
    let l = label(text, f, fg)
    b.addSubview(l)
    let w = fitW(text, f)
    l.frame = NSRect(x: 7, y: 2, width: w, height: 15)
    b.frame.size = NSSize(width: w + 14, height: 19)
    return b
}
