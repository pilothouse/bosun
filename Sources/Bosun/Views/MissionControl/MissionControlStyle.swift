import AppKit
import Domain

// Small building blocks shared by the Mission Control regions (bar, tracker, board, focus cards).
// Each returns a sized view; callers position it.

extension Item {
    /// The item's Mission Control key, `owner/name#number` — what session links and tracker
    /// selection are keyed by.
    var missionKey: String { MissionItemRef(repo: repo, number: number).key }
}

/// A clickable toggle pill whose label and active state update in place, so the bar never rebuilds.
final class MissionPill: FlippedView {
    var onClick: (() -> Void)?
    private let text = label("", mono(9.5, .semibold), .white, align: .center)
    private(set) var title = ""
    private var base: NSColor?
    private var hover: NSColor?
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Set the label and state; returns the width the pill wants.
    @discardableResult
    func update(title: String, active: Bool, theme t: Theme) -> CGFloat {
        let font = mono(9.5, .semibold)
        if title != self.title {
            self.title = title
            text.stringValue = title
        }
        text.font = font
        text.textColor = active ? t.accent : t.txt3
        base = active ? t.accentbg2 : nil
        hover = active ? t.accentbg2 : t.hover
        layer?.backgroundColor = base?.cgColor
        layer?.cornerRadius = z(5)
        needsLayout = true
        return fitW(title, font) + z(14)
    }

    /// Recolor the label (e.g. the "Needs you" filter turns amber while something is waiting).
    func tint(_ color: NSColor) { text.textColor = color }

    override func layout() {
        super.layout()
        text.sizeToFit()
        text.frame = NSRect(x: 0, y: (bounds.height - text.frame.height) / 2, width: bounds.width,
                            height: text.frame.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = hover?.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = base?.cgColor }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// "PR" / "IS" chip in the item's kind color.
func missionKindChip(_ item: Item, theme t: Theme) -> NSView {
    let isPR = item.kind == .pr
    let text = isPR ? "PR" : "IS"
    let color = isPR ? t.accent : Status.yellow
    let font = mono(8)
    let w = fitW(text, font) + z(4)
    let chip = BoxView(bg: color.withAlphaComponent(0.15), radius: z(3))
    chip.frame = NSRect(x: 0, y: 0, width: w, height: z(13))
    let l = label(text, font, color, align: .center)
    l.sizeToFit()
    l.frame = NSRect(x: 0, y: (z(13) - l.frame.height) / 2, width: w, height: l.frame.height)
    chip.addSubview(l)
    return chip
}

/// One issue/PR row (tracker and board): kind chip, number, status, title, and how many sessions
/// are on it.
func missionItemRow(_ item: Item, sessions: Int, selected: Bool, width: CGFloat, height: CGFloat,
                    theme t: Theme, action: @escaping () -> Void) -> ClickRow {
    let row = ClickRow(bg: selected ? t.accentbg : t.card, radius: z(7))
    row.hoverColor = selected ? t.accentbg : t.hover
    row.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let kind = missionKindChip(item, theme: t)
    kind.frame.origin = NSPoint(x: z(8), y: z(7))
    row.addSubview(kind)
    let num = label(item.num, mono(10, .semibold), t.txt)
    num.sizeToFit()
    num.frame.origin = NSPoint(x: kind.frame.maxX + z(6), y: z(6))
    row.addSubview(num)
    let status = label(item.statusLabel, mono(8.5), item.statusColor, align: .right)
    status.frame = NSRect(x: width - z(78), y: z(7), width: z(70), height: z(13))
    row.addSubview(status)
    let title = label(item.title, sys(10.5), t.txt2)
    title.frame = NSRect(x: z(8), y: z(24), width: width - z(16) - (sessions > 0 ? z(34) : 0), height: z(15))
    row.addSubview(title)
    if sessions > 0 {
        let on = label("◆ \(sessions)", mono(8.5), t.accent, align: .right)
        on.frame = NSRect(x: width - z(38), y: z(25), width: z(30), height: z(13))
        row.addSubview(on)
    }
    row.onClick = action
    return row
}

func missionActionButton(_ text: String, width: CGFloat, primary: Bool, theme t: Theme,
                         action: @escaping () -> Void) -> ClickRow {
    let row = ClickRow(bg: primary ? t.accentbg2 : t.card, radius: z(6))
    row.hoverColor = t.hover
    row.frame = NSRect(x: 0, y: 0, width: width, height: z(24))
    row.layer?.borderWidth = 1
    row.layer?.borderColor = (primary ? t.accent.withAlphaComponent(0.4) : t.cardbr).cgColor
    let l = label(text, mono(9.5, .semibold), primary ? t.accent : t.txt3, align: .center)
    l.sizeToFit()
    l.frame = NSRect(x: 0, y: (z(24) - l.frame.height) / 2, width: width, height: l.frame.height)
    row.addSubview(l)
    row.onClick = action
    return row
}

func missionSectionTitle(_ text: String, width: CGFloat, theme t: Theme) -> NSTextField {
    let l = label(text, mono(8.5, .bold), t.txt4)
    l.frame = NSRect(x: z(13), y: 0, width: width - z(26), height: z(13))
    return l
}

func missionLine(_ frame: NSRect, theme t: Theme) -> NSView {
    let line = BoxView(bg: t.line)
    line.frame = frame
    return line
}

/// A vertical list that is rebuilt from scratch but keeps its scroll offset across rebuilds.
final class MissionListView: NSScrollView {
    let doc = FlippedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = doc
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Clear the rows and size the document for `contentHeight`, keeping the current offset.
    func reset(contentHeight: CGFloat) {
        let offset = contentView.bounds.origin
        doc.subviews.forEach { $0.removeFromSuperview() }
        doc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, contentHeight))
        doc.scroll(offset)
    }
}
