import AppKit
import Domain

/// Tile chrome sizes (unscaled points) for a grid of `columns`: denser grids get slimmer headers.
/// Pure styling, so it lives here rather than in Domain.
struct MissionTileMetrics: Equatable {
    let headerHeight: Double
    let nameFontSize: Double
    let cornerRadius: Double
    let gap: Double

    static func forColumns(_ columns: Int) -> MissionTileMetrics {
        columns >= 3
            ? MissionTileMetrics(headerHeight: 22, nameFontSize: 10, cornerRadius: 7, gap: 6)
            : MissionTileMetrics(headerHeight: 24, nameFontSize: 10.5, cornerRadius: 8, gap: 8)
    }
}

/// One Mission Control tile: a slim header (activity, session title, linked item badge) over the
/// session's live terminal surface, which the tile hosts while Mission Control borrows it from the
/// dock. Tiles are pooled per session, so a surface is reparented once when the layout switches in.
///
/// Cheap to repaint: `configure` is a no-op when nothing changed, and the header is rebuilt only when
/// its content or width changes — a busy shell flipping titles doesn't churn the other tiles, and a
/// working tile's spinner keeps animating instead of restarting.
final class MissionTileView: FlippedView {

    /// What the header shows and how the tile is emphasized. Built by `MissionControlView`.
    struct Content: Equatable {
        let title: String
        let activity: MissionTileActivity
        let linkLabel: String?
        /// The linked repo's name, shown when tiles are grouped by repo.
        let repoLabel: String?
        /// The tile's session is linked to the tracker's selected item.
        let highlighted: Bool
        /// The tile holds the active pane (keyboard focus goes here).
        let focused: Bool
        /// Another item is selected and this tile isn't on it.
        let dimmed: Bool
    }

    /// Everything the tile's look depends on; compared to skip redundant repaints.
    private struct Style: Equatable {
        let content: Content
        let geometry: MissionTileMetrics
        let themeKey: String
        let scale: CGFloat
    }

    let sessionId: UUID
    /// Fired by a click on the header — clicks in the body go straight to the terminal surface.
    var onFocus: (() -> Void)?
    /// Fired by the header's × (close this session).
    var onClose: (() -> Void)?
    /// A header drag (reorder): begins past a small threshold, then reports each mouse event, then ends.
    var onDragBegin: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    /// Whether the header can be dragged (off in focus mode, where there's only the hero).
    var dragEnabled: Bool {
        get { header.dragEnabled }
        set { header.dragEnabled = newValue }
    }
    /// Outlines the tile as the place a dragged tile would land.
    var isDropTarget = false { didSet { if oldValue != isDropTarget { applyBorder() } } }

    private let header = MissionTileHeader()
    private let body = FlippedView()
    private let ring = PaneFocusRingView()
    private weak var hosted: NSView?
    private var style: Style?
    private var theme = Theme.operatorTheme
    /// The (style, width) the header was last built for.
    private var headerBuiltFor: (Style, CGFloat)?

    init(sessionId: UUID) {
        self.sessionId = sessionId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        body.wantsLayer = true
        ring.wantsLayer = true
        addSubview(body)
        addSubview(header)
        addSubview(ring)
        header.onClick = { [weak self] in self?.onFocus?() }
        header.onDragBegin = { [weak self] event in self?.onDragBegin?(event) }
        header.onDragMove = { [weak self] event in self?.onDragMove?(event) }
        header.onDragEnd = { [weak self] in self?.onDragEnd?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Move `view` (a lent terminal surface) into this tile. A no-op when it's already here.
    func host(_ view: NSView) {
        guard view.superview !== body else { return }
        body.addSubview(view)
        view.isHidden = false      // the dock hides its inactive tabs' panes; a tile always shows its pane
        view.alphaValue = 1
        hosted = view
        needsLayout = true
    }

    func configure(_ content: Content, geometry: MissionTileMetrics, theme t: Theme) {
        let next = Style(content: content, geometry: geometry, themeKey: t.key, scale: uiScale)
        guard next != style else { return }
        style = next
        theme = t
        let radius = z(geometry.cornerRadius)
        layer?.cornerRadius = radius
        layer?.backgroundColor = t.termBg.cgColor
        applyBorder()
        alphaValue = content.dimmed ? 0.55 : 1
        ring.layer?.cornerRadius = radius
        ring.layer?.borderWidth = content.focused ? 1.6 : 0
        ring.layer?.borderColor = t.accent.cgColor
        // Linked to the tracker selection → tinted header; the accent ring is reserved for keyboard focus.
        header.colors = content.highlighted ? (t.accentbg2, t.accentbg2) : (t.bar, t.hover)
        needsLayout = true
    }

    private func applyBorder() {
        guard let content = style?.content else { return }
        if isDropTarget {
            layer?.borderWidth = 2
            layer?.borderColor = theme.accent.cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = theme.cardbr.cgColor
        }
    }

    override func layout() {
        super.layout()
        let headerHeight = z(style?.geometry.headerHeight ?? 22)
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        body.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        if let hosted, hosted.superview === body, hosted.frame != body.bounds { hosted.frame = body.bounds }
        ring.frame = bounds
        if let style, headerBuiltFor.map({ $0.0 != style || $0.1 != bounds.width }) ?? true {
            headerBuiltFor = (style, bounds.width)
            buildHeader(style, height: headerHeight)
        }
    }

    private func buildHeader(_ style: Style, height h: CGFloat) {
        header.subviews.forEach { $0.removeFromSuperview() }
        let t = theme
        let content = style.content
        let nameFont = mono(style.geometry.nameFontSize, .semibold)
        var x = z(8)
        let dotSize = z(6)
        switch content.activity {
        case .working:
            let spinner = makeSpinner(size: z(10))
            spinner.frame.origin = NSPoint(x: x - z(2), y: (h - z(10)) / 2)
            header.addSubview(spinner)
        case .attention, .idle:
            let dot = Dot(content.activity == .attention ? Status.yellow : Status.green, dotSize)
            dot.frame.origin = NSPoint(x: x, y: (h - dotSize) / 2)
            header.addSubview(dot)
        }
        x += dotSize + z(6)

        // Close (×) at the far right — the tab strip's × isn't visible in Mission Control.
        let closeSize = min(z(18), h - z(2))
        let close = ClickRow(radius: z(4))
        close.hoverColor = t.hover
        close.toolTip = "Close session (⌘W)"
        close.frame = NSRect(x: bounds.width - z(4) - closeSize, y: (h - closeSize) / 2, width: closeSize, height: closeSize)
        let glyph = label("×", sys(12), t.txt3, align: .center)
        glyph.sizeToFit()
        glyph.frame = NSRect(x: 0, y: (closeSize - glyph.frame.height) / 2, width: closeSize, height: glyph.frame.height)
        close.addSubview(glyph)
        close.onClick = { [weak self] in self?.onClose?() }
        header.addSubview(close)
        var trailing = close.frame.minX - z(6)
        if let repo = content.repoLabel {
            let font = mono(max(7, style.geometry.nameFontSize - 1.5))
            let l = label(repo, font, t.txt3, align: .right)
            l.sizeToFit()
            let w = min(l.frame.width, bounds.width * 0.35)
            l.frame = NSRect(x: trailing - w, y: (h - l.frame.height) / 2, width: w, height: l.frame.height)
            header.addSubview(l)
            trailing -= w + z(8)
        }
        if let link = content.linkLabel {
            let font = mono(max(7, style.geometry.nameFontSize - 1.5))
            let w = fitW(link, font) + z(6)
            let chipH = min(z(14), h - z(4))
            let chip = BoxView(bg: content.highlighted ? t.accentbg2 : t.accentbg, radius: z(3))
            chip.frame = NSRect(x: trailing - w, y: (h - chipH) / 2, width: w, height: chipH)
            let l = label(link, font, t.accent, align: .center)
            l.sizeToFit()
            l.frame = NSRect(x: 0, y: (chipH - l.frame.height) / 2, width: w, height: l.frame.height)
            chip.addSubview(l)
            header.addSubview(chip)
            trailing -= w + z(6)
        }

        let name = label(content.title, nameFont, content.focused ? t.txt : t.txt2)
        name.sizeToFit()
        name.frame = NSRect(x: x, y: (h - name.frame.height) / 2, width: max(0, trailing - x),
                            height: name.frame.height)
        header.addSubview(name)
    }
}

/// A tile's header: hover highlight, a click to focus the tile, and a drag to reorder it. The drag
/// runs its own tracking loop (like `DragHandle`) so the gesture survives Mission Control relaying out
/// mid-drag; a press that never moves past the threshold is a plain click.
final class MissionTileHeader: FlippedView {
    var onClick: (() -> Void)?
    var onDragBegin: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    var dragEnabled = true { didSet { window?.invalidateCursorRects(for: self) } }
    var colors: (base: NSColor, hover: NSColor) = (.clear, .clear) {
        didSet { layer?.backgroundColor = colors.base.cgColor }
    }
    private var tracking: NSTrackingArea?
    private static let dragThreshold: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        if dragEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = colors.hover.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = colors.base.cgColor }

    override func mouseDown(with event: NSEvent) {
        guard let window else { onClick?(); return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let p = next.locationInWindow
            if !dragging, dragEnabled, hypot(p.x - start.x, p.y - start.y) >= Self.dragThreshold {
                dragging = true
                NSCursor.closedHand.push()
                onDragBegin?(event)
            }
            if dragging {
                onDragMove?(next)
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        if dragging {
            NSCursor.pop()
            onDragEnd?()
        } else {
            onClick?()
        }
    }
}
