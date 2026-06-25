import AppKit

/// A flipped container so manual frames lay out top-to-bottom.
class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The app-wide zoom multiplier — the App-layer mirror of `Domain.UIZoom.scale`. Every font helper
/// (`mono`/`sys`) and every laid-out constant (`z`) reads it, so one value scales the whole GUI in
/// lockstep with the terminal (⌘+ / ⌘− / ⌘0). Single writer: `Store` calls `setUIScale` whenever
/// `uiZoom` changes, then triggers a full view rebuild so every `layout()` re-reads it. A plain
/// module global (not on `Store`) because the 153 font call sites and the manual layout math are
/// free functions with no store reference; `Sources/Bosun` is the unconstrained composition layer,
/// so a mirror here crosses no architecture boundary.
private(set) var uiScale: CGFloat = 1.0
func setUIScale(_ scale: CGFloat) { uiScale = scale }

/// Scale a layout constant (point size, width, padding, radius) by the current zoom. The seam the
/// manual `layout()` passes wrap their literals in so geometry grows with the fonts.
func z(_ value: CGFloat) -> CGFloat { value * uiScale }

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size * uiScale, weight: weight)
}
func sys(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size * uiScale, weight: weight)
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
    /// When set, the row shows this cursor on hover (e.g. a pointing hand for link-like rows).
    var cursor: NSCursor?
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
    override func resetCursorRects() { if let cursor { addCursorRect(bounds, cursor: cursor) } }
}

/// A deliberately slim scroller for cramped strips (the 32pt terminal tab bar). NSScrollView renders
/// the ~15pt legacy scroller whenever the system "Show scroll bars" setting resolves to *Always* — or
/// to *Automatic* with a mouse attached — which swamps such a short bar even though the strip asks for
/// `.overlay`. We override only the class width (for BOTH styles, so it stays slim however the setting
/// resolves) and let AppKit draw its standard knob/track at that width — so the indicator is still
/// visible and draggable, just thin. `isCompatibleWithOverlayScrollers` keeps overlay fade working.
final class ThinScroller: NSScroller {
    static let thickness: CGFloat = 7

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { thickness }
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

/// An avatar / org icon: shows a colored-initials placeholder immediately, then async-loads the
/// real image (via `AvatarLoader`) and swaps it in, clipped to `cornerRadius`. Pass
/// `cornerRadius == size/2` for a circle (users) or a small radius for a rounded square (orgs).
/// `ring` draws a thin accent border (used for bot/agent accounts). Because the panels rebuild
/// every `layout()`, a cache hit renders synchronously here — no initials flash on relayout — and
/// a load that finishes after the view is gone is a harmless no-op (the completion captures `self`
/// weakly).
final class AvatarView: NSView {
    private weak var initials: NSTextField?

    init(size: CGFloat, cornerRadius: CGFloat, url: URL?,
         placeholderColor: NSColor, initials: String,
         initialsFont: NSFont, initialsColor: NSColor,
         ring: NSColor? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.contentsScale = Self.backingScale(for: nil)
        if let ring {
            layer?.borderWidth = 1.5
            layer?.borderColor = ring.cgColor
        }

        // Placeholder: solid fill + centered initials. The 12pt label height reproduces the prior
        // hand-tuned offsets for the 20/22/26pt avatars exactly (y = 4/5/7); it scales with the zoom
        // so the centering stays exact as `size`/`initialsFont` grow.
        layer?.backgroundColor = placeholderColor.cgColor
        let il = label(initials, initialsFont, initialsColor, align: .center)
        il.frame = NSRect(x: 0, y: (size - z(12)) / 2, width: size, height: z(12))
        addSubview(il)
        self.initials = il

        guard let url else { return }
        let loader = AvatarLoader.shared
        if let cached = loader.cachedImage(for: url) { apply(cached); return }
        loader.load(url) { [weak self] image in self?.apply(image) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func apply(_ image: NSImage) {
        layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsScale = Self.backingScale(for: window)
        layer?.backgroundColor = nil   // image now covers the placeholder fill
        initials?.removeFromSuperview()
        initials = nil
    }

    // Keep the layer's scale matched to the screen so the avatar stays sharp on Retina and when the
    // window is dragged between displays of different scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = Self.backingScale(for: window)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = Self.backingScale(for: window)
    }

    private static func backingScale(for window: NSWindow?) -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
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
    let b = BoxView(bg: bg, radius: z(5), border: border)
    let f = monospaced ? mono(10.5) : sys(10.5, .semibold)
    let l = label(text, f, fg)
    // A plain NSTextField top-aligns its text, so a fixed-height frame leaves slack at the bottom and
    // the word sits high. Collapse the label to its exact line height (sizeToFit) and center that in
    // the box, so ISSUE / PR / EPIC sit vertically centered inside the bordered chip. The pill's
    // height/padding scale with the zoom so the chip grows with its (already-scaled) text.
    l.sizeToFit()
    let w = fitW(text, f)
    let h: CGFloat = z(19)
    l.frame = NSRect(x: z(7), y: ((h - l.frame.height) / 2).rounded(), width: w, height: l.frame.height)
    b.addSubview(l)
    b.frame.size = NSSize(width: w + z(14), height: h)
    return b
}
