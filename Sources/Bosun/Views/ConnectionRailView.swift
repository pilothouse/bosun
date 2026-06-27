import AppKit
import Domain

final class ConnectionRailView: FlippedView {
    let store: Store
    var onAdd: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onToggleFavorite: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    /// A drag reordered a section: (the section's ids in their pre-move display order, the moved
    /// row's old index, its new index). The App layer applies `ConnectionOrdering` and persists.
    var onReorder: (([UUID], Int, Int) -> Void)?

    // Double-click is tracked here, not via the row's clickCount: selecting a connection rebuilds
    // the rail and replaces the row between the two clicks, so AppKit's native double-click
    // detection fired only intermittently ("sometimes doesn't open").
    private var lastClickId: String?
    private var lastClickAt: TimeInterval = 0

    /// Live "Search connections" filter. The query is rail-local transient state (like the detail
    /// composer's draft), deliberately *not* in `Store`: it must not persist and must not route
    /// through `store.notify()` — a notify per keystroke would tear the whole rail down and drop the
    /// field's focus mid-type. Typing instead rebuilds only the list document below the (sibling)
    /// field via `repopulateList()`, so the field keeps its focus and insertion point.
    private var searchQuery = ""
    private weak var searchField: NSTextField?
    private weak var listScroll: NSScrollView?

    // Live drag-to-reorder state, mirroring `ManageOrgsSheet` but scoped to one section. Captured
    // by `makeListDocument` so a grip drag can reposition that section's live rows without a full
    // rebuild; `draggingId != nil` also blocks the rebuild so the gesture isn't torn down mid-drag.
    private weak var listDoc: FlippedView?
    private var rowsById: [String: ClickRow] = [:]
    private var sectionIdsById: [String: [String]] = [:]   // id → its section's ids, in display order
    private var sectionTopById: [String: CGFloat] = [:]     // id → its section's first-row top-Y in doc
    private var draggingId: String?
    private var dragOrder: [String] = []                    // live order of the dragged row's section
    private var dragGrabDY: CGFloat = 0
    private var dragSectionTop: CGFloat = 0

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }
    override func layout() { super.layout(); rebuild() }

    private func sectionHeader(_ title: String, accentStar: Bool, count: String?, width: CGFloat, t: Theme) -> NSView {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: z(26)))
        var x: CGFloat = z(14)
        if accentStar {
            let s = label("★", sys(11), t.accent)
            s.frame = NSRect(x: x, y: z(6), width: z(14), height: z(14)); v.addSubview(s); x += z(18)
        }
        let l = label(title, mono(9.5, .semibold), t.txt4)
        l.frame = NSRect(x: x, y: z(6), width: width - x - z(30), height: z(14))
        v.addSubview(l)
        if let count {
            let c = label(count, mono(10), t.txt5, align: .right)
            c.frame = NSRect(x: width - z(30), y: z(6), width: z(16), height: z(14)); v.addSubview(c)
        }
        return v
    }

    private func connRow(_ c: Connection, width: CGFloat, t: Theme, reorderable: Bool) -> ClickRow {
        let selected = store.selectedConnId == c.id
        let row = ClickRow(bg: selected ? t.accentbg : nil)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 0, y: 0, width: width, height: z(42))
        // Single click selects; a quick second click on the same row opens a console (SSH connects,
        // a folder opens a shell there).
        row.onClick = { [weak self] in self?.handleRowClick(c.id) }

        // Drag-to-reorder grip: a ☰ handle in the left gutter, revealed only while the row is
        // hovered so the resting list stays uncluttered. A drag on it moves the row within its
        // section; a click elsewhere on the row still selects (the grip eats only its own zone).
        if reorderable {
            let grip = DragGrip(frame: NSRect(x: 0, y: 0, width: z(14), height: z(42)))
            grip.alphaValue = 0
            let gl = label("☰", sys(11), t.txt4, align: .center)
            gl.frame = NSRect(x: 0, y: (z(42) - z(14)) / 2, width: z(14), height: z(14))
            grip.addSubview(gl)
            grip.onDown = { [weak self] e in self?.beginDrag(c.id, event: e) }
            grip.onDrag = { [weak self] e in self?.updateDrag(event: e) }
            grip.onUp = { [weak self] _ in self?.endDrag() }
            row.addSubview(grip)
            row.onHoverChange = { [weak grip] hovering in grip?.alphaValue = hovering ? 1 : 0 }
        }

        if selected {
            let bar = BoxView(bg: t.accent)
            bar.frame = NSRect(x: 0, y: 0, width: z(2), height: z(42))
            row.addSubview(bar)
        }
        let glyph = label(c.glyph, sys(13), t.txt3)
        glyph.frame = NSRect(x: z(14), y: z(12), width: z(16), height: z(16))
        row.addSubview(glyph)

        let name = label(c.name, sys(12.5, .semibold), selected ? t.txt : t.txt2)
        name.frame = NSRect(x: z(34), y: z(6), width: width - z(34) - z(40), height: z(16))
        row.addSubview(name)

        let meta = label(c.meta, mono(10), t.txt4)
        meta.frame = NSRect(x: z(34), y: z(22), width: width - z(34) - z(40), height: z(13))
        row.addSubview(meta)

        let dot = Dot(c.dot, z(7))
        dot.frame.origin = NSPoint(x: width - z(38), y: z(18))
        row.addSubview(dot)

        // Clickable star toggles favorite (independent of the row's select-on-click).
        let starHit = ClickRow(radius: z(5))
        starHit.frame = NSRect(x: width - z(30), y: z(8), width: z(24), height: z(26))
        starHit.hoverColor = t.hover
        starHit.onClick = { [weak self] in self?.onToggleFavorite?(c.id) }
        let star = label(c.isFavorite ? "★" : "☆", sys(12), c.isFavorite ? t.accent : t.txt5, align: .center)
        star.frame = NSRect(x: 0, y: z(6), width: z(24), height: z(14))
        starHit.addSubview(star)
        row.addSubview(starHit)

        // Right-click → Connect / Open / Edit / Delete.
        let menu = NSMenu()
        let openTitle = c.kind == .ssh ? "Connect" : "Open in Terminal"
        let connect = NSMenuItem(title: openTitle, action: #selector(connectMenuAction(_:)), keyEquivalent: "")
        connect.target = self; connect.representedObject = c.id
        menu.addItem(connect)
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit…", action: #selector(editMenuAction(_:)), keyEquivalent: "")
        edit.target = self; edit.representedObject = c.id
        let remove = NSMenuItem(title: "Delete", action: #selector(deleteMenuAction(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = c.id
        menu.addItem(edit); menu.addItem(remove)
        row.menu = menu
        return row
    }

    /// Single click selects; a second click on the same row within the system double-click
    /// interval opens its console. Timed here on the rail (which survives the selection rebuild)
    /// rather than relying on the row instance's clickCount.
    private func handleRowClick(_ id: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastClickId == id, now - lastClickAt <= NSEvent.doubleClickInterval {
            lastClickId = nil
            onConnect?(id)
        } else {
            lastClickId = id
            lastClickAt = now
            store.selectedConnId = id
        }
    }

    @objc private func connectMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onConnect?(id) }
    }
    @objc private func editMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onEdit?(id) }
    }
    @objc private func deleteMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onDelete?(id) }
    }

    /// A muted, bordered card holding a wrapped message. With `tap` it highlights on hover and runs
    /// the closure on click (the no-connections prompt opens the New-connection sheet); without it
    /// the card is inert (the no-matches notice). Height hugs the wrapped text so there's no slack.
    private func emptyHint(_ text: String, width: CGFloat, t: Theme, tap: (() -> Void)? = nil) -> ClickRow {
        let rowW = width - z(28)
        let pad: CGFloat = z(11)
        let textW = rowW - z(24)
        let l = label(text, sys(11.5), t.txt4, lines: 0)
        l.preferredMaxLayoutWidth = textW
        let textH = ceil(l.fittingSize.height)
        l.frame = NSRect(x: z(12), y: pad, width: textW, height: textH)
        let row = ClickRow(bg: t.card, radius: z(8))
        if let tap {
            row.hoverColor = t.hover
            row.onClick = tap
        }
        row.frame = NSRect(x: z(14), y: 0, width: rowW, height: textH + pad * 2)
        row.layer?.borderColor = t.line2.cgColor
        row.layer?.borderWidth = z(1)
        row.addSubview(l)
        return row
    }

    private func rebuild() {
        // Never tear the rows down mid-drag — the gesture repositions the live views directly.
        if draggingId != nil { return }
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = t.panel.cgColor
        let w = bounds.width
        guard w > 60 else { return }   // collapsed

        // Right border.
        let border = BoxView(bg: t.line)
        border.frame = NSRect(x: w - z(1), y: 0, width: z(1), height: bounds.height)
        addSubview(border)

        // Search header: an editable field that filters the list live as the user types (⌘K
        // focuses it). Styled borderless like the detail composer so it blends into the card.
        let search = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
        search.frame = NSRect(x: z(14), y: z(12), width: w - z(28), height: z(34))
        let mag = label("⌕", sys(13), t.txt4)
        mag.frame = NSRect(x: z(10), y: z(8), width: z(16), height: z(18)); search.addSubview(mag)
        let field = NSTextField(string: searchQuery)
        field.font = sys(12.5)
        field.placeholderString = "Search connections…"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = t.txt
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
        field.frame = NSRect(x: z(30), y: z(8), width: w - z(28) - z(70), height: z(18))
        search.addSubview(field)
        searchField = field
        let kbd = BoxView(bg: t.hover, radius: z(4))
        kbd.frame = NSRect(x: w - z(28) - z(38), y: z(9), width: z(28), height: z(16))
        // Center the glyphs on both axes inside the pill (a plain label top-aligns its text, so
        // "⌘K" sat high); same treatment as the footer "+".
        let kl = centeredGlyph("⌘K", mono(10), t.txt5, in: kbd.frame.size)
        kbd.addSubview(kl); search.addSubview(kbd)
        addSubview(search)

        // Footer.
        let footerH: CGFloat = z(48)
        let footer = ClickRow(bg: nil)
        footer.hoverColor = t.hover
        footer.onClick = { [weak self] in self?.onAdd?() }
        footer.frame = NSRect(x: 0, y: bounds.height - footerH, width: w, height: footerH)
        let ftBorder = BoxView(bg: t.line)
        ftBorder.frame = NSRect(x: 0, y: 0, width: w, height: z(1)); footer.addSubview(ftBorder)
        // The "+" box, the label, and the ⌘N hint all share the footer's vertical midline.
        let mid = footerH / 2
        let plusSize: CGFloat = z(26)
        let plus = BoxView(bg: nil, radius: z(7), border: t.line2)
        plus.frame = NSRect(x: z(14), y: mid - plusSize / 2, width: plusSize, height: plusSize)
        let pl = centeredGlyph("+", sys(16), t.txt4, in: plus.frame.size)
        plus.addSubview(pl); footer.addSubview(plus)
        let ftH: CGFloat = z(18)
        let ftLabel = label("New connection", sys(11.5), t.txt3)
        ftLabel.frame = NSRect(x: z(49), y: mid - ftH / 2, width: w - z(49) - z(40), height: ftH); footer.addSubview(ftLabel)
        let cmdN = label("⌘N", mono(10), t.txt5, align: .right)
        cmdN.frame = NSRect(x: w - z(44), y: mid - ftH / 2, width: z(30), height: ftH); footer.addSubview(cmdN)
        addSubview(footer)

        // Scrollable list. Its document is built by `makeListDocument` so a keystroke can rebuild
        // just the document (keeping the sibling search field focused), not the whole rail.
        let top: CGFloat = z(56)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: top, width: w, height: bounds.height - top - footerH))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = makeListDocument(width: w, minHeight: scroll.frame.height, t: t)
        addSubview(scroll)
        listScroll = scroll
    }

    /// Build the (filtered) connection list as a fresh document view. Each section is narrowed by the
    /// current `searchQuery` via the pure `ConnectionSearch` rule (an empty query yields the full list).
    private func makeListDocument(width w: CGFloat, minHeight: CGFloat, t: Theme) -> FlippedView {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: z(10)))
        listDoc = doc
        rowsById = [:]; sectionIdsById = [:]; sectionTopById = [:]
        var y: CGFloat = z(6)

        func section(_ title: String, _ items: [Connection], star: Bool, count: String?) {
            guard !items.isEmpty else { return }   // hide a section with nothing in it
            let head = sectionHeader(title, accentStar: star, count: count, width: w, t: t)
            head.frame.origin.y = y; doc.addSubview(head); y += z(28)
            // A lone row can't be reordered; only show grips (and capture drag state) for 2+.
            let reorderable = items.count >= 2
            let ids = items.map(\.id)
            let firstRowTop = y
            for c in items {
                let r = connRow(c, width: w, t: t, reorderable: reorderable)
                r.frame.origin.y = y; doc.addSubview(r); y += z(42)
                if reorderable {
                    rowsById[c.id] = r
                    sectionIdsById[c.id] = ids
                    sectionTopById[c.id] = firstRowTop
                }
            }
            y += z(8)
        }
        func place(_ hint: NSView) { hint.frame.origin.y = y; doc.addSubview(hint); y += hint.frame.height + z(4) }

        if store.connections.isEmpty {
            // Whole-rail empty state: one merged prompt, no section headers.
            place(emptyHint("No connections yet. Press ⌘N to add an SSH remote or a local folder.",
                            width: w, t: t, tap: { [weak self] in self?.onAdd?() }))
        } else {
            let query = searchQuery
            func keep(_ c: Connection) -> Bool { ConnectionSearch.matches(query: query, in: c.name, c.meta) }
            let favs = store.favorites.filter(keep)
            let ssh = store.sshRemotes.filter(keep)
            let folders = store.folders.filter(keep)
            section("FAVORITES", favs, star: true, count: "\(favs.count)")
            section("SSH REMOTES", ssh, star: false, count: nil)
            section("LOCAL FOLDERS", folders, star: false, count: nil)
            if favs.isEmpty, ssh.isEmpty, folders.isEmpty {
                // A live query that matched nothing — distinct from the no-connections state above.
                let shown = query.trimmingCharacters(in: .whitespacesAndNewlines)
                place(emptyHint("No connections match “\(shown)”.", width: w, t: t))
            }
        }

        doc.frame.size.height = max(y, minHeight)
        return doc
    }

    /// Rebuild only the list document in response to a keystroke, leaving the (sibling) search field
    /// untouched so it keeps first-responder status and its insertion point.
    private func repopulateList() {
        guard let scroll = listScroll else { return }
        scroll.documentView = makeListDocument(width: scroll.frame.width,
                                                minHeight: scroll.frame.height, t: store.theme)
    }

    /// Focus the search field (the ⌘K target). The field exists only when the rail is expanded; the
    /// App layer expands the rail first (see `BosunView.focusConnectionSearch`).
    func focusSearch() {
        guard let field = searchField else { return }
        window?.makeFirstResponder(field)
    }

    // MARK: Drag-to-reorder (within a section)

    private func beginDrag(_ id: String, event: NSEvent) {
        guard let doc = listDoc, let row = rowsById[id],
              let sectionIds = sectionIdsById[id], let top = sectionTopById[id] else { return }
        draggingId = id
        dragOrder = sectionIds
        dragSectionTop = top
        let p = doc.convert(event.locationInWindow, from: nil)
        dragGrabDY = p.y - row.frame.origin.y
        doc.addSubview(row)                 // raise above siblings
        row.layer?.shadowColor = NSColor.black.cgColor
        row.layer?.shadowOpacity = 0.35
        row.layer?.shadowRadius = z(8)
        row.layer?.shadowOffset = CGSize(width: 0, height: z(2))
        row.layer?.masksToBounds = false
        row.setBase(store.theme.card)       // show the row as "picked up"
    }

    private func updateDrag(event: NSEvent) {
        guard let id = draggingId, let doc = listDoc, let row = rowsById[id],
              let from = dragOrder.firstIndex(of: id) else { return }
        let n = dragOrder.count
        let h = z(42)
        let p = doc.convert(event.locationInWindow, from: nil)
        let minY = dragSectionTop, maxY = dragSectionTop + CGFloat(n - 1) * h
        let newTop = max(minY, min(maxY, p.y - dragGrabDY))
        row.frame.origin.y = newTop

        var target = Int(((newTop + h / 2) - dragSectionTop) / h)
        target = max(0, min(n - 1, target))
        if target != from { dragOrder.insert(dragOrder.remove(at: from), at: target) }

        // Reflow the non-dragged rows into their slots so the gap follows the cursor.
        for (i, rid) in dragOrder.enumerated() where rid != id {
            rowsById[rid]?.frame.origin.y = dragSectionTop + CGFloat(i) * h
        }
    }

    private func endDrag() {
        guard let id = draggingId else { return }
        draggingId = nil
        // A move is a single element shifting from its old slot to its new one: report that as
        // (original section order, from, to) and let the App layer persist it — the store update
        // triggers the settling rebuild. A no-op (or a plain grip click) just settles the visuals.
        if let original = sectionIdsById[id],
           let from = original.firstIndex(of: id),
           let to = dragOrder.firstIndex(of: id), from != to {
            onReorder?(original.compactMap(UUID.init(uuidString:)), from, to)
        } else {
            repopulateList()
        }
    }
}

extension ConnectionRailView: NSTextFieldDelegate {
    /// Live-filter the list as the user types. Updates only the rail-local query and the list
    /// document — never `store.notify()` — so the field keeps focus while the list below it changes.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === searchField else { return }
        searchQuery = field.stringValue
        repopulateList()
    }

    /// Esc clears an active filter (and the field) instead of AppKit's default "revert" behavior.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField, selector == #selector(NSResponder.cancelOperation(_:)),
              !(searchField?.stringValue.isEmpty ?? true) else { return false }
        searchField?.stringValue = ""
        searchQuery = ""
        repopulateList()
        return true
    }
}
