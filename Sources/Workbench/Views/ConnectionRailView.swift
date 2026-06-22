import AppKit

final class ConnectionRailView: FlippedView {
    let store: Store
    var onAdd: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onToggleFavorite: ((String) -> Void)?

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
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        var x: CGFloat = 14
        if accentStar {
            let s = label("★", sys(11), t.accent)
            s.frame = NSRect(x: x, y: 6, width: 14, height: 14); v.addSubview(s); x += 18
        }
        let l = label(title, mono(9.5, .semibold), t.txt4)
        l.frame = NSRect(x: x, y: 6, width: width - x - 30, height: 14)
        v.addSubview(l)
        if let count {
            let c = label(count, mono(10), t.txt5, align: .right)
            c.frame = NSRect(x: width - 30, y: 6, width: 16, height: 14); v.addSubview(c)
        }
        return v
    }

    private func connRow(_ c: Connection, width: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedConnId == c.id
        let row = ClickRow(bg: selected ? t.accentbg : nil)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 0, y: 0, width: width, height: 42)
        row.onClick = { [weak self] in self?.store.selectedConnId = c.id }

        if selected {
            let bar = BoxView(bg: t.accent)
            bar.frame = NSRect(x: 0, y: 0, width: 2, height: 42)
            row.addSubview(bar)
        }
        let glyph = label(c.glyph, sys(13), t.txt3)
        glyph.frame = NSRect(x: 14, y: 12, width: 16, height: 16)
        row.addSubview(glyph)

        let name = label(c.name, sys(12.5, .semibold), selected ? t.txt : t.txt2)
        name.frame = NSRect(x: 34, y: 6, width: width - 34 - 40, height: 16)
        row.addSubview(name)

        let meta = label(c.meta, mono(10), t.txt4)
        meta.frame = NSRect(x: 34, y: 22, width: width - 34 - 40, height: 13)
        row.addSubview(meta)

        let dot = Dot(c.dot, 7)
        dot.frame.origin = NSPoint(x: width - 38, y: 18)
        row.addSubview(dot)

        // Clickable star toggles favorite (independent of the row's select-on-click).
        let starHit = ClickRow(radius: 5)
        starHit.frame = NSRect(x: width - 30, y: 8, width: 24, height: 26)
        starHit.hoverColor = t.hover
        starHit.onClick = { [weak self] in self?.onToggleFavorite?(c.id) }
        let star = label(c.isFavorite ? "★" : "☆", sys(12), c.isFavorite ? t.accent : t.txt5, align: .center)
        star.frame = NSRect(x: 0, y: 6, width: 24, height: 14)
        starHit.addSubview(star)
        row.addSubview(starHit)

        // Right-click → Edit / Delete.
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit…", action: #selector(editMenuAction(_:)), keyEquivalent: "")
        edit.target = self; edit.representedObject = c.id
        let remove = NSMenuItem(title: "Delete", action: #selector(deleteMenuAction(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = c.id
        menu.addItem(edit); menu.addItem(remove)
        row.menu = menu
        return row
    }

    @objc private func editMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onEdit?(id) }
    }
    @objc private func deleteMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onDelete?(id) }
    }

    /// Whole-rail empty state: a muted, bordered card that also opens the New-connection
    /// sheet when clicked. Height hugs the wrapped text so there's no slack at the bottom.
    private func emptyHint(_ text: String, width: CGFloat, t: Theme) -> ClickRow {
        let rowW = width - 28
        let pad: CGFloat = 11
        let textW = rowW - 24
        let l = label(text, sys(11.5), t.txt4, lines: 0)
        l.preferredMaxLayoutWidth = textW
        let textH = ceil(l.fittingSize.height)
        l.frame = NSRect(x: 12, y: pad, width: textW, height: textH)
        let row = ClickRow(bg: t.card, radius: 8)
        row.hoverColor = t.hover
        row.onClick = { [weak self] in self?.onAdd?() }
        row.frame = NSRect(x: 14, y: 0, width: rowW, height: textH + pad * 2)
        row.layer?.borderColor = t.line2.cgColor
        row.layer?.borderWidth = 1
        row.addSubview(l)
        return row
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = t.panel.cgColor
        let w = bounds.width
        guard w > 60 else { return }   // collapsed

        // Right border.
        let border = BoxView(bg: t.line)
        border.frame = NSRect(x: w - 1, y: 0, width: 1, height: bounds.height)
        addSubview(border)

        // Search header.
        let search = BoxView(bg: t.card, radius: 8, border: t.cardbr)
        search.frame = NSRect(x: 14, y: 12, width: w - 28, height: 34)
        let mag = label("⌕", sys(13), t.txt4)
        mag.frame = NSRect(x: 10, y: 8, width: 16, height: 18); search.addSubview(mag)
        let ph = label("Search connections…", sys(12.5), t.txt4)
        ph.frame = NSRect(x: 30, y: 8, width: w - 28 - 70, height: 18); search.addSubview(ph)
        let kbd = BoxView(bg: t.hover, radius: 4)
        kbd.frame = NSRect(x: w - 28 - 38, y: 9, width: 28, height: 16)
        let kl = label("⌘K", mono(10), t.txt5, align: .center)
        kl.frame = kbd.bounds; kbd.addSubview(kl); search.addSubview(kbd)
        addSubview(search)

        // Footer.
        let footerH: CGFloat = 48
        let footer = ClickRow(bg: nil)
        footer.hoverColor = t.hover
        footer.onClick = { [weak self] in self?.onAdd?() }
        footer.frame = NSRect(x: 0, y: bounds.height - footerH, width: w, height: footerH)
        let ftBorder = BoxView(bg: t.line)
        ftBorder.frame = NSRect(x: 0, y: 0, width: w, height: 1); footer.addSubview(ftBorder)
        // The "+" box, the label, and the ⌘N hint all share the footer's vertical midline.
        let mid = footerH / 2
        let plusSize: CGFloat = 26
        let plus = BoxView(bg: nil, radius: 7, border: t.line2)
        plus.frame = NSRect(x: 14, y: mid - plusSize / 2, width: plusSize, height: plusSize)
        let pl = centeredGlyph("+", sys(16), t.txt4, in: plus.frame.size)
        plus.addSubview(pl); footer.addSubview(plus)
        let ftH: CGFloat = 18
        let ftLabel = label("New connection", sys(11.5), t.txt3)
        ftLabel.frame = NSRect(x: 49, y: mid - ftH / 2, width: w - 49 - 40, height: ftH); footer.addSubview(ftLabel)
        let cmdN = label("⌘N", mono(10), t.txt5, align: .right)
        cmdN.frame = NSRect(x: w - 44, y: mid - ftH / 2, width: 30, height: ftH); footer.addSubview(cmdN)
        addSubview(footer)

        // Scrollable list.
        let top: CGFloat = 56
        let scroll = NSScrollView(frame: NSRect(x: 0, y: top, width: w, height: bounds.height - top - footerH))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: 10))
        var y: CGFloat = 6

        func section(_ title: String, _ items: [Connection], star: Bool, count: String?) {
            guard !items.isEmpty else { return }   // hide a section with nothing in it
            let head = sectionHeader(title, accentStar: star, count: count, width: w, t: t)
            head.frame.origin.y = y; doc.addSubview(head); y += 28
            for c in items {
                let r = connRow(c, width: w, t: t)
                r.frame.origin.y = y; doc.addSubview(r); y += 42
            }
            y += 8
        }
        if store.connections.isEmpty {
            // Whole-rail empty state: one merged prompt, no section headers.
            let hint = emptyHint("No connections yet. Press ⌘N to add an SSH remote or a local folder.", width: w, t: t)
            hint.frame.origin.y = y; doc.addSubview(hint); y += hint.frame.height + 4
        } else {
            section("FAVORITES", store.favorites, star: true, count: "\(store.favorites.count)")
            section("SSH REMOTES", store.sshRemotes, star: false, count: nil)
            section("LOCAL FOLDERS", store.folders, star: false, count: nil)
        }

        doc.frame.size.height = max(y, scroll.frame.height)
        scroll.documentView = doc
        addSubview(scroll)
    }
}
