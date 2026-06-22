import AppKit

/// Scrollable issue/PR detail for the currently-selected item.
final class DetailView: FlippedView {
    let store: Store
    private let scroll = NSScrollView()

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        rebuild()
    }

    private func wrapped(_ text: String, _ font: NSFont, _ color: NSColor, width: CGFloat) -> NSTextField {
        let l = label(text, font, color, lines: 0)
        l.preferredMaxLayoutWidth = width
        let h = l.sizeThatFits(NSSize(width: width, height: 100000)).height
        l.frame = NSRect(x: 0, y: 0, width: width, height: ceil(h))
        return l
    }

    private func rebuild() {
        let t = store.theme
        layer?.backgroundColor = t.win.cgColor
        let avail = bounds.width
        guard avail > 80 else { scroll.documentView = nil; return }

        let padX: CGFloat = 26
        let cw = min(avail - padX * 2, 720)
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: avail, height: 10))
        var y: CGFloat = 20

        guard let it = store.selectedItem else {
            let empty = label("Select an item", sys(14), t.txt4)
            empty.frame = NSRect(x: padX, y: 30, width: cw, height: 20); doc.addSubview(empty)
            doc.frame.size.height = 80; scroll.documentView = doc; return
        }

        func add(_ v: NSView, x: CGFloat = padX) { v.frame.origin = NSPoint(x: x, y: y); doc.addSubview(v) }

        // Type row.
        let typeLabel: String = it.epic ? "EPIC" : (it.kind == .pr ? "PR" : "ISSUE")
        let typeColor: NSColor = it.epic ? Status.purple : (it.kind == .pr ? t.accent : t.txt3)
        let tb = badge(typeLabel, fg: typeColor, border: typeColor, mono: false)
        tb.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(tb)
        let repoNum = label("\(it.repo) \(it.num)", mono(12), t.txt3)
        repoNum.frame = NSRect(x: padX + tb.frame.width + 10, y: y + 2, width: 280, height: 16); doc.addSubview(repoNum)
        let stat = label(it.statusLabel, mono(11, .semibold).asMono, it.statusColor, align: .right)
        stat.frame = NSRect(x: padX + cw - 160, y: y + 2, width: 160, height: 16); doc.addSubview(stat)
        y += 30

        // Title.
        let title = wrapped(it.title, sys(21, .bold), t.txt, width: cw)
        add(title); y += title.frame.height + 11

        // Author row.
        let avatar = Dot(it.authorColor, 20)
        avatar.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(avatar)
        let ai = label(it.authorInitials, sys(9, .bold), .hex(0x0d0f13), align: .center)
        ai.frame = NSRect(x: 0, y: 4, width: 20, height: 12); avatar.addSubview(ai)
        var rx = padX + 28
        let auth = label(it.author, sys(12, .semibold), t.txt2); auth.frame = NSRect(x: rx, y: y + 3, width: fitW(auth), height: 16); doc.addSubview(auth); rx += auth.frame.width + 9
        let opened = label("opened \(it.age)", sys(12), t.txt4); opened.frame = NSRect(x: rx, y: y + 3, width: fitW(opened), height: 16); doc.addSubview(opened); rx += opened.frame.width + 9
        if let branch = it.branch {
            let b = badge("⎇ \(branch)", fg: t.accent, bg: t.accentbg2)
            b.frame.origin = NSPoint(x: rx, y: y); doc.addSubview(b); rx += b.frame.width + 9
        }
        if let a = it.add, let d = it.del {
            let diff = label("+\(a) −\(d)", mono(10.5), t.txt3); diff.frame = NSRect(x: rx, y: y + 3, width: 90, height: 16); doc.addSubview(diff); rx += 96
        }
        if let blocked = it.blocked {
            let bb = badge("⊘ \(blocked)", fg: Status.red, bg: .hexA(0xf85149, 0.12)); bb.frame.origin = NSPoint(x: rx, y: y); doc.addSubview(bb)
        }
        y += 30

        // Hydration spinner: the lead item renders immediately; signal that the full body, tasks,
        // comments and checks are still being fetched (only on first load, before any detail lands).
        if store.isLoadingDetail && store.selectedItemDetail == nil {
            let spinner = makeSpinner(size: 14)
            spinner.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(spinner)
            let loading = label("Loading details…", sys(11.5), t.txt4)
            loading.frame = NSRect(x: padX + 22, y: y, width: 200, height: 16); doc.addSubview(loading)
            y += 26
        }

        // Body card.
        let bodyText = wrapped(it.body, sys(13.5), t.txt2, width: cw - 34)
        var cardH = bodyText.frame.height + 30
        var taskViews: [NSView] = []
        if !it.tasks.isEmpty {
            cardH += 20
            for task in it.tasks {
                let row = FlippedView(frame: NSRect(x: 17, y: 0, width: cw - 34, height: 22))
                let box = BoxView(bg: task.done ? t.accent : nil, radius: 4, border: task.done ? t.accent : t.txt4)
                box.frame = NSRect(x: 0, y: 3, width: 15, height: 15)
                if task.done { box.addSubview(centeredGlyph("✓", sys(9, .bold), .hex(0x0d0f13), in: box.frame.size)) }
                row.addSubview(box)
                let tl = label(task.label, sys(12.5), task.done ? t.txt4 : t.txt2)
                tl.frame = NSRect(x: 24, y: 3, width: cw - 34 - 24, height: 16); row.addSubview(tl)
                taskViews.append(row)
                cardH += 26
            }
        }
        let card = BoxView(bg: t.card, radius: 11, border: t.cardbr)
        card.frame = NSRect(x: padX, y: y, width: cw, height: cardH)
        bodyText.frame.origin = NSPoint(x: 17, y: 15); card.addSubview(bodyText)
        var ty = bodyText.frame.maxY + 13
        if !taskViews.isEmpty {
            let lbl = label("TASKS", mono(9.5, .semibold), t.txt4); lbl.frame = NSRect(x: 17, y: ty, width: 200, height: 13); card.addSubview(lbl); ty += 18
            for tv in taskViews { tv.frame.origin.y = ty; card.addSubview(tv); ty += 26 }
        }
        doc.addSubview(card); y += cardH + 20

        // PR checks.
        if it.kind == .pr && !it.checks.isEmpty {
            let passed = it.checks.filter { $0.statusText == "passed" }.count
            let hdr = label("ACTIONS · \(passed)/\(it.checks.count) passing", mono(9.5, .semibold), t.txt4)
            hdr.frame = NSRect(x: padX, y: y, width: cw, height: 14); doc.addSubview(hdr); y += 24
            let box = BoxView(bg: t.card, radius: 11, border: t.cardbr)
            let rowH: CGFloat = 38
            box.frame = NSRect(x: padX, y: y, width: cw, height: rowH * CGFloat(it.checks.count))
            var cy: CGFloat = 0
            for (i, c) in it.checks.enumerated() {
                let row = FlippedView(frame: NSRect(x: 0, y: cy, width: cw, height: rowH))
                let icon = BoxView(bg: .hexA(UInt32(c.color.toHex()), 0.12), radius: 5, border: c.color)
                icon.frame = NSRect(x: 14, y: 11, width: 16, height: 16)
                icon.addSubview(centeredGlyph(c.icon, sys(9), c.color, in: icon.frame.size)); row.addSubview(icon)
                let nm = label(c.name, sys(12.5, .medium), t.txt2); nm.frame = NSRect(x: 40, y: 11, width: cw - 220, height: 16); row.addSubview(nm)
                let stt = label(c.statusText, mono(10.5), c.color, align: .right); stt.frame = NSRect(x: cw - 180, y: 11, width: 110, height: 16); row.addSubview(stt)
                let dur = label(c.dur, mono(10), t.txt4, align: .right); dur.frame = NSRect(x: cw - 62, y: 11, width: 48, height: 16); row.addSubview(dur)
                if i < it.checks.count - 1 {
                    let sep = BoxView(bg: t.line); sep.frame = NSRect(x: 0, y: rowH - 1, width: cw, height: 1); row.addSubview(sep)
                }
                box.addSubview(row); cy += rowH
            }
            doc.addSubview(box); y += box.frame.height + 22
        }

        // Comments.
        let chdr = label("COMMENTS · \(it.comments.count)", mono(9.5, .semibold), t.txt4)
        chdr.frame = NSRect(x: padX, y: y, width: cw, height: 14); doc.addSubview(chdr); y += 22
        for cm in it.comments {
            let av = Dot(cm.color, 26); av.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(av)
            let ai = label(cm.initials, sys(10, .bold), .hex(0x0d0f13), align: .center); ai.frame = NSRect(x: 0, y: 7, width: 26, height: 12); av.addSubview(ai)
            let bubbleW = cw - 37
            let body = wrapped(cm.body, sys(12.5), t.txt2, width: bubbleW - 26)
            let bubbleH = body.frame.height + 38
            let bubble = BoxView(bg: t.card, radius: 11, border: t.cardbr)
            bubble.frame = NSRect(x: padX + 37, y: y, width: bubbleW, height: bubbleH)
            let an = label(cm.author, sys(12, .bold), t.txt); an.frame = NSRect(x: 13, y: 11, width: 200, height: 16); bubble.addSubview(an)
            let tm = label(cm.time, sys(11), t.txt4, align: .right); tm.frame = NSRect(x: bubbleW - 90, y: 11, width: 76, height: 16); bubble.addSubview(tm)
            if !cm.badge.isEmpty {
                let bg = badge(cm.badge, fg: t.accent, border: t.accent); bg.frame.origin = NSPoint(x: 13 + fitW(an) + 8, y: 9); bubble.addSubview(bg)
            }
            body.frame.origin = NSPoint(x: 13, y: 30); bubble.addSubview(body)
            doc.addSubview(bubble); y += bubbleH + 13
        }

        // Composer.
        let cav = NSView(frame: NSRect(x: padX, y: y, width: 26, height: 26))
        cav.wantsLayer = true
        let g = CAGradientLayer(); g.frame = cav.bounds; g.colors = [NSColor.hex(0x7c8cff).cgColor, NSColor.hex(0xd2a8ff).cgColor]; g.cornerRadius = 13
        cav.layer?.addSublayer(g); doc.addSubview(cav)
        let comp = BoxView(bg: t.card, radius: 10, border: t.cardbr)
        comp.frame = NSRect(x: padX + 37, y: y, width: cw - 37, height: 38)
        let cph = label("Comment, or @claude to delegate…", sys(12.5), t.txt4); cph.frame = NSRect(x: 12, y: 11, width: cw - 200, height: 16); comp.addSubview(cph)
        let send = BoxView(bg: t.accent, radius: 7); send.frame = NSRect(x: cw - 37 - 64, y: 7, width: 56, height: 24)
        let sl = label("Send", sys(11, .semibold), t.onacc, align: .center); sl.frame = NSRect(x: 0, y: 4, width: 56, height: 16); send.addSubview(sl); comp.addSubview(send)
        doc.addSubview(comp); y += 50

        doc.frame.size.height = y + 10
        scroll.documentView = doc
    }
}

private extension NSFont { var asMono: NSFont { self } }

extension NSColor {
    /// Best-effort RGB hex (used to re-tint check icons).
    func toHex() -> Int {
        guard let c = usingColorSpace(.sRGB) else { return 0x6b7079 }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return (r << 16) | (g << 8) | b
    }
}
