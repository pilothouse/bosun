import AppKit
import Domain

/// Items in the repo scope as tracker entries. An item "needs you" when a session linked to it rang.
func missionTrackerEntries(_ snap: MissionSnapshot, repoKey: String?) -> [TrackerEntry] {
    let ringing = Set(snap.tiles.filter { $0.activity == .attention }.compactMap(\.linkedItemKey))
    return snap.items
        .filter { item in repoKey.map { item.repo == $0 } ?? true }
        .map { item in
            TrackerEntry(key: item.missionKey, isPullRequest: item.kind == .pr, isDraft: item.isDraft,
                         isAgent: item.isAgent, needsYou: ringing.contains(item.missionKey))
        }
}

/// One rendered item row's inputs — what a rebuild depends on.
private func rowSignature(_ item: Item, snap: MissionSnapshot, selectedKey: String?) -> String {
    let sessions = snap.links.values.filter { $0 == item.missionKey }.count
    return "\(item.missionKey)|\(item.title)|\(item.statusLabel)|\(sessions)|\(selectedKey == item.missionKey)"
}

/// The tracker rail: issues/PRs grouped into sections (`TrackerGrouping`), with the selected item's
/// detail card (checks, attach / zoom). Rebuilt only when its inputs change — not on every repaint.
final class MissionTrackerView: FlippedView {
    var onSelect: ((Item) -> Void)?
    var onAttach: (() -> Void)?
    var onZoom: (() -> Void)?

    private let list = MissionListView()
    private var signature: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(list)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    func update(snap: MissionSnapshot, selectedKey: String?, repoKey: String?, detail: Item?, theme t: Theme) {
        let entries = missionTrackerEntries(snap, repoKey: repoKey)
        let itemsByKey = Dictionary(snap.items.map { ($0.missionKey, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = TrackerGrouping.groups(entries)
        let selected = selectedKey.flatMap { itemsByKey[$0] }
        // The hydrated detail (with checks) once it lands for the selected item.
        let selectedDetail = selected.flatMap { item in detail?.missionKey == item.missionKey ? detail : item }

        var next = groups.flatMap { group in
            ["#\(group.kind.rawValue)"] + group.entries.compactMap { itemsByKey[$0.key] }
                .map { rowSignature($0, snap: snap, selectedKey: selectedKey) }
        }
        next += [selectedKey ?? "", snap.focusedTitle ?? "", repoKey ?? "", t.key, "\(uiScale)", "\(bounds.size)"]
        next += selectedDetail.map { $0.checks.map { "\($0.name)|\($0.icon)|\($0.dur)" } } ?? []
        next += snap.panes.filter { snap.links[$0.id] == selectedKey }.map(\.title)
        guard next != signature else { return }
        signature = next
        rebuild(groups: groups, itemsByKey: itemsByKey, selected: selectedDetail, snap: snap,
                selectedKey: selectedKey, repoKey: repoKey, theme: t)
    }

    private func rebuild(groups: [TrackerGroup], itemsByKey: [String: Item], selected: Item?, snap: MissionSnapshot,
                         selectedKey: String?, repoKey: String?, theme t: Theme) {
        subviews.filter { $0 !== list }.forEach { $0.removeFromSuperview() }
        layer?.backgroundColor = t.panel.cgColor
        let w = bounds.width
        addSubview(missionLine(NSRect(x: 0, y: 0, width: 1, height: bounds.height), theme: t))
        let title = missionSectionTitle("TRACKER · \(repoKey ?? "all repos")", width: w, theme: t)
        title.frame.origin.y = z(11)
        addSubview(title)
        let hint = label("Select an item to highlight its sessions · \(snap.focusedTitle ?? "nothing") focused",
                         sys(10.5), t.txt4, lines: 2)
        hint.frame = NSRect(x: z(13), y: z(28), width: w - z(26), height: z(28))
        addSubview(hint)
        var y = z(60)
        if let selected {
            let card = selectedCard(selected, snap: snap, width: w, theme: t)
            card.frame.origin = NSPoint(x: 0, y: y)
            addSubview(card)
            y += card.frame.height
        }

        let rowH = z(44), headerH = z(22)
        let contentH = groups.reduce(z(8)) { $0 + headerH + CGFloat($1.entries.count) * (rowH + z(4)) + z(6) }
        list.frame = NSRect(x: 0, y: y, width: w, height: max(0, bounds.height - y))
        list.reset(contentHeight: contentH)
        var rowY = z(6)
        for group in groups {
            let head = missionSectionTitle("\(Self.title(group.kind).uppercased())  \(group.entries.count)", width: w, theme: t)
            head.frame.origin.y = rowY + z(4)
            list.doc.addSubview(head)
            rowY += headerH
            for entry in group.entries {
                guard let item = itemsByKey[entry.key] else { continue }
                let sessions = snap.links.values.filter { $0 == entry.key }.count
                let row = missionItemRow(item, sessions: sessions, selected: entry.key == selectedKey,
                                         width: w - z(18), height: rowH, theme: t) { [weak self] in
                    self?.onSelect?(item)
                }
                row.frame.origin = NSPoint(x: z(9), y: rowY)
                list.doc.addSubview(row)
                rowY += rowH + z(4)
            }
            rowY += z(6)
        }
    }

    static func title(_ kind: TrackerGroupKind) -> String {
        switch kind {
        case .needsYou: return "Needs you"
        case .agentPullRequests: return "PRs · agent"
        case .pullRequests: return "PRs"
        case .draftPullRequests: return "Draft PRs"
        case .issues: return "Issues"
        }
    }

    /// The selected item: title, repo/author, its CI checks once the detail lands, and the actions.
    private func selectedCard(_ item: Item, snap: MissionSnapshot, width: CGFloat, theme t: Theme) -> NSView {
        let card = BoxView(bg: t.accentbg)
        let inner = width - z(26)
        var y = z(10)
        let kind = missionKindChip(item, theme: t)
        kind.frame.origin = NSPoint(x: z(13), y: y + z(1))
        card.addSubview(kind)
        let num = label("\(item.num)  ·  \(item.statusLabel)", mono(10.5, .bold), t.txt)
        num.frame = NSRect(x: kind.frame.maxX + z(7), y: y, width: inner - kind.frame.width - z(7), height: z(15))
        card.addSubview(num)
        y += z(20)
        let title = label(item.title, sys(12, .semibold), t.txt, lines: 2)
        title.frame = NSRect(x: z(13), y: y, width: inner, height: z(32))
        card.addSubview(title)
        y += z(34)
        let meta = label("\(item.repo)  \(item.author)  \(item.age)", mono(9), t.txt4)
        meta.frame = NSRect(x: z(13), y: y, width: inner, height: z(13))
        card.addSubview(meta)
        y += z(18)
        for check in item.checks.prefix(5) {
            let icon = label(check.icon, mono(9), check.color)
            icon.frame = NSRect(x: z(13), y: y, width: z(12), height: z(13))
            card.addSubview(icon)
            let name = label(check.name, mono(9.5), t.txt2)
            name.frame = NSRect(x: z(28), y: y, width: inner - z(70), height: z(13))
            card.addSubview(name)
            let dur = label(check.dur, mono(9), t.txt4, align: .right)
            dur.frame = NSRect(x: width - z(70), y: y, width: z(57), height: z(13))
            card.addSubview(dur)
            y += z(16)
        }
        y += z(6)
        let attach = missionActionButton("attach focused session", width: inner - z(86), primary: true, theme: t) { [weak self] in
            self?.onAttach?()
        }
        attach.frame.origin = NSPoint(x: z(13), y: y)
        card.addSubview(attach)
        let zoom = missionActionButton("zoom", width: z(80), primary: false, theme: t) { [weak self] in
            self?.onZoom?()
        }
        zoom.frame.origin = NSPoint(x: width - z(13) - z(80), y: y)
        card.addSubview(zoom)
        y += z(30)
        let onIt = snap.panes.filter { snap.links[$0.id] == item.missionKey }.map(\.title)
        if !onIt.isEmpty {
            let on = label("on it: " + onIt.joined(separator: ", "), mono(9), t.accent, lines: 2)
            on.frame = NSRect(x: z(13), y: y, width: inner, height: z(26))
            card.addSubview(on)
            y += z(28)
        }
        card.frame = NSRect(x: 0, y: 0, width: width, height: y + z(4))
        card.addSubview(missionLine(NSRect(x: 0, y: card.frame.height - 1, width: width, height: 1), theme: t))
        return card
    }
}

/// Board mode's four-column issue/PR board (`TrackerGrouping.board`). Rebuilt only when its inputs change.
final class MissionBoardView: FlippedView {
    var onSelect: ((Item) -> Void)?
    private var signature: [String] = []

    func update(snap: MissionSnapshot, selectedKey: String?, repoKey: String?, theme t: Theme) {
        let itemsByKey = Dictionary(snap.items.map { ($0.missionKey, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = TrackerGrouping.board(missionTrackerEntries(snap, repoKey: repoKey))
        var next = columns.flatMap { column in
            ["#\(column.column.rawValue)"] + column.entries.compactMap { itemsByKey[$0.key] }
                .map { rowSignature($0, snap: snap, selectedKey: selectedKey) }
        }
        next += [t.key, "\(uiScale)", "\(bounds.size)"]
        guard next != signature else { return }
        signature = next

        subviews.forEach { $0.removeFromSuperview() }
        wantsLayer = true
        layer?.backgroundColor = t.panel.cgColor
        addSubview(missionLine(NSRect(x: 0, y: 0, width: bounds.width, height: 1), theme: t))
        let head = missionSectionTitle("ISSUE & PR BOARD", width: bounds.width, theme: t)
        head.frame.origin.y = z(9)
        addSubview(head)
        let gap = z(7), top = z(28)
        let colW = (bounds.width - gap * CGFloat(columns.count + 1)) / CGFloat(columns.count)
        let colH = bounds.height - top - gap
        for (i, column) in columns.enumerated() {
            let col = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
            col.frame = NSRect(x: gap + CGFloat(i) * (colW + gap), y: top, width: colW, height: colH)
            let title = label("\(Self.title(column.column))  \(column.entries.count)", mono(9.5, .bold), t.txt)
            title.frame = NSRect(x: z(10), y: z(7), width: colW - z(20), height: z(14))
            col.addSubview(title)
            let cardH = z(44)
            let list = MissionListView(frame: NSRect(x: 0, y: z(26), width: colW, height: colH - z(26)))
            list.reset(contentHeight: CGFloat(column.entries.count) * (cardH + z(5)) + z(6))
            for (j, entry) in column.entries.enumerated() {
                guard let item = itemsByKey[entry.key] else { continue }
                let sessions = snap.links.values.filter { $0 == entry.key }.count
                let row = missionItemRow(item, sessions: sessions, selected: entry.key == selectedKey,
                                         width: colW - z(14), height: cardH, theme: t) { [weak self] in
                    self?.onSelect?(item)
                }
                row.frame.origin = NSPoint(x: z(7), y: CGFloat(j) * (cardH + z(5)))
                list.doc.addSubview(row)
            }
            col.addSubview(list)
            addSubview(col)
        }
    }

    private static func title(_ column: TrackerBoardColumn) -> String {
        switch column {
        case .issues: return "Issues"
        case .drafts: return "Draft PRs"
        case .ready: return "Ready PRs"
        case .agent: return "Agent PRs"
        }
    }
}
