import AppKit
import Domain

/// Mission Control's control bar. Left to right: view (Grid · Focus), layout presets drawn as the
/// literal grid shape (Grid only), the activity filter with live counts, then — right-aligned — the
/// repo scope chip (when narrowed), the pager (only when there's more than one page) and the options
/// menu. Built once; `update` re-styles in place and is a no-op when nothing changed.
final class MissionBarView: FlippedView {

    struct State: Equatable {
        let view: MissionView
        let preset: MissionLayoutPreset
        /// What `auto` resolved to — outlined so the user sees the shape Auto picked.
        let resolved: MissionLayoutPreset
        let filter: MissionFilter
        let counts: [Int]   // all, working, attention
        let page: Int
        let pageCount: Int
        /// Fixed presets whose tiles would be narrower/shorter than a usable terminal in this area.
        let cramped: Set<MissionLayoutPreset>
        let repoTitle: String?
        let themeKey: String
        let scale: CGFloat
    }

    var onView: ((MissionView) -> Void)?
    var onPreset: ((MissionLayoutPreset) -> Void)?
    var onFilter: ((MissionFilter) -> Void)?
    var onPage: ((Int) -> Void)?
    var onClearRepo: (() -> Void)?
    /// Asks the owner to show the options menu anchored under the given view.
    var onOptions: ((NSView) -> Void)?

    private let viewPills = MissionView.allCases.map { _ in MissionPill() }
    private let presetButtons = MissionLayoutPreset.allCases.map { MissionPresetButton(preset: $0) }
    private let filterPills = MissionFilter.allCases.map { _ in MissionPill() }
    private let repoChip = MissionPill()
    private let previousPage = MissionPill()
    private let pageLabel = label("", mono(10, .semibold), .gray, align: .center)
    private let nextPage = MissionPill()
    private let optionsPill = MissionPill()
    private let line = BoxView()
    private var state: State?
    private var theme = Theme.operatorTheme
    private var widths: [ObjectIdentifier: CGFloat] = [:]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for (pill, view) in zip(viewPills, MissionView.allCases) {
            pill.onClick = { [weak self] in self?.onView?(view) }
            pill.toolTip = "⌃⌘\((MissionView.allCases.firstIndex(of: view) ?? 0) + 1)"
        }
        for button in presetButtons {
            button.onClick = { [weak self] in self?.onPreset?(button.preset) }
        }
        for (pill, filter) in zip(filterPills, MissionFilter.allCases) {
            pill.onClick = { [weak self] in self?.onFilter?(filter) }
        }
        repoChip.onClick = { [weak self] in self?.onClearRepo?() }
        repoChip.toolTip = "Click to show all repos"
        previousPage.onClick = { [weak self] in self?.onPage?(-1) }
        previousPage.toolTip = "Previous page (⌃⌘↑)"
        nextPage.onClick = { [weak self] in self?.onPage?(1) }
        nextPage.toolTip = "Next page (⌃⌘↓)"
        optionsPill.onClick = { [weak self] in
            guard let self else { return }
            self.onOptions?(self.optionsPill)
        }
        optionsPill.toolTip = "Repo scope, grouping and tracker"
        (viewPills + filterPills).forEach(addSubview)
        presetButtons.forEach(addSubview)
        [repoChip, previousPage, pageLabel, nextPage, optionsPill, line].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Which pager arrow (−1 / +1) is under `point` (this view's coordinates), for spring-loaded
    /// page flips while dragging a tile; nil when over neither or when there's only one page.
    func pageArrow(at point: NSPoint) -> Int? {
        if !previousPage.isHidden, previousPage.frame.insetBy(dx: -z(6), dy: -z(6)).contains(point) { return -1 }
        if !nextPage.isHidden, nextPage.frame.insetBy(dx: -z(6), dy: -z(6)).contains(point) { return 1 }
        return nil
    }

    /// Highlight the arrow a dragged tile is hovering (it flips the page after a short delay).
    func highlightArrow(_ direction: Int?) {
        previousPage.tint(direction == -1 ? Status.yellow : theme.txt3)
        nextPage.tint(direction == 1 ? Status.yellow : theme.txt3)
    }

    func update(_ next: State, theme t: Theme) {
        guard next != state else { return }
        state = next
        theme = t
        layer?.backgroundColor = t.bar.cgColor
        line.style(bg: t.line)
        func set(_ pill: MissionPill, _ text: String, _ active: Bool) {
            widths[ObjectIdentifier(pill)] = pill.update(title: text, active: active, theme: t)
        }
        for (pill, view) in zip(viewPills, MissionView.allCases) { set(pill, view.rawValue.capitalized, next.view == view) }
        let labels = ["All", "Working", "Needs you"]
        for (index, (pill, filter)) in zip(filterPills, MissionFilter.allCases).enumerated() {
            set(pill, "\(labels[index]) \(next.counts[index])", next.filter == filter)
        }
        let attention = filterPills[2]
        if next.counts[2] > 0, next.filter != .attention { attention.tint(Status.yellow) }
        for button in presetButtons {
            button.isHidden = next.view != .grid
            let cramped = next.cramped.contains(button.preset)
            button.update(active: next.preset == button.preset,
                          resolved: next.preset == .auto && next.resolved == button.preset,
                          cramped: cramped, theme: t)
            button.toolTip = button.preset == .auto
                ? "Auto — picks the biggest grid that keeps terminals usable (now \(next.resolved.title))"
                : "\(button.preset.title) — \(button.preset.shape.map { $0.columns * $0.rows } ?? 0) per page"
                    + (cramped ? " (cramped here: terminals under 64×16)" : "")
        }
        repoChip.isHidden = next.repoTitle == nil
        if let repo = next.repoTitle { set(repoChip, "\(repo)  ✕", true) }
        let paged = next.view == .grid && next.pageCount > 1
        [previousPage, pageLabel, nextPage].forEach { $0.isHidden = !paged }
        set(previousPage, "‹", false)
        set(nextPage, "›", false)
        pageLabel.stringValue = "\(next.page + 1) / \(next.pageCount)"
        pageLabel.font = mono(10, .semibold)
        pageLabel.textColor = t.txt2
        set(optionsPill, "options ▾", false)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let h = z(22), y = (bounds.height - z(22)) / 2
        var x = z(10)
        func place(_ view: NSView, width: CGFloat, gap: CGFloat = z(2)) {
            view.frame = NSRect(x: x, y: y, width: width, height: h)
            x += width + gap
        }
        for pill in viewPills { place(pill, width: widths[ObjectIdentifier(pill)] ?? z(44)) }
        x += z(14)
        if state?.view == .grid {
            for button in presetButtons { place(button, width: button.preset == .auto ? z(40) : z(28)) }
            x += z(14)
        }
        for pill in filterPills { place(pill, width: widths[ObjectIdentifier(pill)] ?? z(50)) }

        var right = bounds.width - z(10)
        func placeRight(_ view: NSView, width: CGFloat, gap: CGFloat = z(2)) {
            right -= width
            view.frame = NSRect(x: right, y: y, width: width, height: h)
            right -= gap
        }
        placeRight(optionsPill, width: widths[ObjectIdentifier(optionsPill)] ?? z(70), gap: z(12))
        if !nextPage.isHidden {
            placeRight(nextPage, width: z(24))
            pageLabel.sizeToFit()
            let labelW = max(z(44), pageLabel.frame.width + z(8))
            right -= labelW
            pageLabel.frame = NSRect(x: right, y: (bounds.height - pageLabel.frame.height) / 2, width: labelW,
                                     height: pageLabel.frame.height)
            right -= z(2)
            placeRight(previousPage, width: z(24), gap: z(12))
        }
        if !repoChip.isHidden { placeRight(repoChip, width: widths[ObjectIdentifier(repoChip)] ?? z(120)) }
    }
}

extension MissionLayoutPreset {
    /// Display name: the literal shape ("2×2"), or "Auto".
    var title: String {
        guard let shape else { return "Auto" }
        return shape.columns == 1 && shape.rows == 1 ? "1" : "\(shape.columns)×\(shape.rows)"
    }
}

/// A layout preset button that draws its grid shape (a 2×2 preset shows four small cells), so the
/// icon *is* the layout you get. Auto shows the word. `resolved` outlines the shape Auto picked.
final class MissionPresetButton: FlippedView {
    let preset: MissionLayoutPreset
    var onClick: (() -> Void)?
    private var active = false
    private var resolved = false
    /// Dimmed (still clickable) when the shape would make terminals too small in this area.
    private var cramped = false
    private var hovering = false
    private var theme = Theme.operatorTheme
    private var tracking: NSTrackingArea?

    init(preset: MissionLayoutPreset) {
        self.preset = preset
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(active: Bool, resolved: Bool, cramped: Bool, theme t: Theme) {
        self.active = active
        self.resolved = resolved
        self.cramped = cramped
        alphaValue = cramped && !active ? 0.4 : 1
        theme = t
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        let box = bounds.insetBy(dx: 1, dy: 1)
        let background = active ? t.accentbg2 : hovering ? t.hover : NSColor.clear
        background.setFill()
        NSBezierPath(roundedRect: box, xRadius: z(5), yRadius: z(5)).fill()
        if resolved {
            t.accent.withAlphaComponent(0.6).setStroke()
            let ring = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: z(5), yRadius: z(5))
            ring.lineWidth = 1
            ring.setLineDash([2, 2], count: 2, phase: 0)
            ring.stroke()
        }
        let ink = active ? t.accent : t.txt3
        guard let shape = preset.shape else {
            let text = NSAttributedString(string: "Auto", attributes: [.font: mono(9.5, .semibold), .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }
        let icon = NSRect(x: (bounds.width - z(16)) / 2, y: (bounds.height - z(12)) / 2, width: z(16), height: z(12))
        let gap: CGFloat = 1.5
        let cellW = (icon.width - gap * CGFloat(shape.columns - 1)) / CGFloat(shape.columns)
        let cellH = (icon.height - gap * CGFloat(shape.rows - 1)) / CGFloat(shape.rows)
        ink.setFill()
        for row in 0..<shape.rows {
            for column in 0..<shape.columns {
                let cell = NSRect(x: icon.minX + CGFloat(column) * (cellW + gap), y: icon.minY + CGFloat(row) * (cellH + gap),
                                  width: cellW, height: cellH)
                NSBezierPath(roundedRect: cell, xRadius: 1, yRadius: 1).fill()
            }
        }
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

/// Mission Control's bottom bar: where you are ("Sessions 5–8 of 12 · page 2/3 · 2×2") and the
/// shortcuts. Updated in place.
final class MissionStatusView: FlippedView {
    private let position = label("", mono(10), .gray)
    private let hints = label("", mono(10), .gray, align: .right)
    private let line = BoxView()
    private var last: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        [position, hints, line].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    func update(position text: String, hints hintText: String, theme t: Theme) {
        let next = [text, hintText, t.key, "\(uiScale)"]
        guard next != last else { return }
        last = next
        layer?.backgroundColor = t.bar.cgColor
        line.style(bg: t.line)
        position.stringValue = text
        position.font = mono(10, .semibold)
        position.textColor = t.txt3
        hints.stringValue = hintText
        hints.font = mono(10)
        hints.textColor = t.txt4
        needsLayout = true
    }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        position.sizeToFit()
        position.frame.origin = NSPoint(x: z(12), y: (bounds.height - position.frame.height) / 2)
        hints.sizeToFit()
        hints.frame.origin = NSPoint(x: bounds.width - hints.frame.width - z(12),
                                     y: (bounds.height - hints.frame.height) / 2)
    }
}

/// A strip that appears only while sessions need the user (they rang the bell): one chip per session,
/// in any view. A click jumps to that session — flipping the page if it's elsewhere.
final class MissionAttentionBanner: FlippedView {
    var onFocus: ((UUID) -> Void)?
    private var signature: [String] = []

    func update(tiles attention: [MissionTile], theme t: Theme) {
        let next = attention.map { "\($0.id)|\($0.title)" } + [t.key, "\(uiScale)", "\(bounds.width)"]
        guard next != signature else { return }
        signature = next
        subviews.forEach { $0.removeFromSuperview() }
        wantsLayer = true
        layer?.backgroundColor = Status.yellow.withAlphaComponent(0.10).cgColor
        let head = label("▲ NEEDS YOU", mono(9, .bold), Status.yellow)
        head.sizeToFit()
        head.frame.origin = NSPoint(x: z(12), y: (bounds.height - head.frame.height) / 2)
        addSubview(head)
        var x = head.frame.maxX + z(10)
        for tile in attention {
            let font = mono(9.5, .semibold)
            let w = min(fitW(tile.title, font) + z(22), z(260))
            guard x + w < bounds.width - z(8) else { break }
            let chip = ClickRow(bg: t.card, radius: z(6))
            chip.hoverColor = t.hover
            chip.frame = NSRect(x: x, y: (bounds.height - z(20)) / 2, width: w, height: z(20))
            let dot = Dot(Status.yellow, z(5))
            dot.frame.origin = NSPoint(x: z(7), y: (z(20) - z(5)) / 2)
            chip.addSubview(dot)
            let l = label(tile.title, font, t.txt)
            l.frame = NSRect(x: z(16), y: (z(20) - z(13)) / 2, width: w - z(22), height: z(13))
            chip.addSubview(l)
            if let id = UUID(uuidString: tile.id) { chip.onClick = { [weak self] in self?.onFocus?(id) } }
            addSubview(chip)
            x += w + z(6)
        }
    }
}
