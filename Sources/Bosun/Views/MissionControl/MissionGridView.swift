import AppKit
import Domain

/// The area Mission Control's tiles live in. It never scrolls: the grid shows one page that exactly
/// fills it (see `MissionPagePolicy`), so live terminals are never composited inside a scroll view and
/// a scroll over a tile always means that terminal's scrollback.
final class MissionGridView: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }
}

/// An empty grid slot: a dashed outline with "+ New session" — clicking opens a local terminal tab,
/// which lands in this slot (new tabs append to the end).
final class MissionEmptySlotView: FlippedView {
    var onClick: (() -> Void)?
    private let text = label("+  New session", mono(10.5, .semibold), .gray, align: .center)
    private var themeKey = ""
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private var theme = Theme.operatorTheme

    /// Only the first empty slot carries the "+ New session" label; the rest stay quiet outlines so a
    /// mostly-empty page doesn't repeat the same call to action.
    var showsLabel = true { didSet { text.isHidden = !showsLabel } }

    func apply(theme t: Theme) {
        guard t.key != themeKey else { return }
        themeKey = t.key
        theme = t
        text.textColor = t.txt4
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: z(8), yRadius: z(8))
        if hovering {
            theme.hover.setFill()
            path.fill()
        }
        theme.line2.setStroke()
        path.lineWidth = 1
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func layout() {
        super.layout()
        text.font = mono(10.5, .semibold)
        text.sizeToFit()
        text.frame = NSRect(x: 0, y: (bounds.height - text.frame.height) / 2, width: bounds.width, height: text.frame.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Focus mode's side list: one compact card per visible session that isn't the hero — status,
/// title, linked item. A click makes that session the hero. Cards carry no live terminal, so
/// switching the hero resizes one surface instead of reflowing every session.
final class MissionFocusCardsView: FlippedView {
    var onFocus: ((UUID) -> Void)?
    private let list = MissionListView()
    private let head = label("", mono(8.5, .bold), .gray)
    private var signature: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(head)
        addSubview(list)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    func update(snap: MissionSnapshot, hero: UUID?, theme t: Theme) {
        let others = snap.visible.filter { $0.id != hero?.uuidString }
        let next = others.map { tile -> String in
            let id = UUID(uuidString: tile.id) ?? UUID()
            let color = snap.colors[id]?.rawValue ?? ""
            return "\(tile.id)|\(tile.title)|\(tile.activity)|\(snap.links[id] ?? "")|\(color)"
        }
            + [t.key, "\(uiScale)", "\(bounds.size)", "\(snap.highlightActivity)"]
        guard next != signature else { return }
        signature = next
        layer?.backgroundColor = t.panel.cgColor
        head.stringValue = "SESSIONS · \(others.count)"
        head.font = mono(8.5, .bold)
        head.textColor = t.txt4
        head.frame = NSRect(x: z(13), y: z(11), width: bounds.width - z(26), height: z(13))
        let top = z(30)
        list.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let cardH = z(46), gap = z(5)
        list.reset(contentHeight: CGFloat(others.count) * (cardH + gap) + z(8))
        for (i, tile) in others.enumerated() {
            guard let id = UUID(uuidString: tile.id) else { continue }
            let card = ClickRow(bg: t.card, radius: z(7))
            card.hoverColor = t.hover
            card.frame = NSRect(x: z(8), y: CGFloat(i) * (cardH + gap), width: bounds.width - z(16), height: cardH)
            // A colored connection's card gets the rail's solid leading stripe (#102), clipped to the
            // card's rounded corners. The dot below keeps its status meaning.
            if let color = snap.colors[id] {
                card.layer?.masksToBounds = true
                let stripe = BoxView(bg: t.swatch(color))
                stripe.frame = NSRect(x: 0, y: 0, width: z(3), height: cardH)
                card.addSubview(stripe)
            }
            let (color, state) = cardStatus(tile.activity, highlight: snap.highlightActivity, theme: t)
            let dot = Dot(color, z(6))
            dot.frame.origin = NSPoint(x: z(10), y: z(11))
            card.addSubview(dot)
            let name = label(tile.title, mono(10, .semibold), t.txt)
            name.frame = NSRect(x: z(22), y: z(7), width: card.frame.width - z(30), height: z(15))
            card.addSubview(name)
            let meta = label([state, snap.links[id].map { "→ \($0)" }].compactMap { $0 }.joined(separator: "   "),
                             mono(9), t.txt4)
            meta.frame = NSRect(x: z(22), y: z(25), width: card.frame.width - z(30), height: z(13))
            card.addSubview(meta)
            card.onClick = { [weak self] in self?.onFocus?(id) }
            list.doc.addSubview(card)
        }
    }

    /// The card's status dot color and word. With "Highlight activity" on (#103), green means
    /// "finished, not yet seen" only, so quiet sessions go gray.
    private func cardStatus(_ activity: MissionTileActivity, highlight: Bool, theme t: Theme) -> (NSColor, String) {
        switch activity {
        case .attention: return (Status.yellow, "needs you")
        case .working: return (t.accent, "working")
        case .done: return (Status.green, "done")
        case .idle: return (highlight ? Status.dim : Status.green, "idle")
        }
    }
}
