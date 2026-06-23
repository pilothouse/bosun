import AppKit

/// Scrollable issue/PR detail for the currently-selected item.
final class DetailView: FlippedView {
    let store: Store
    private let scroll = NSScrollView()
    private let linkDelegate = MarkdownLinkDelegate()
    // Memoized Markdown renders so `rebuild()` (run on every `layout()` pass) doesn't re-parse.
    // The attributed string is width-independent; only the cheap height measurement uses width.
    private var mdCache: [String: NSAttributedString] = [:]
    private var mdThemeKey = ""

    /// Called when the user submits a comment. The view hands over the text and a completion the
    /// controller runs on the main actor: `(true, nil)` clears the composer; `(false, message)`
    /// keeps the draft so the user can retry and surfaces `message`.
    var onSubmitComment: ((String, @escaping (Bool, String?) -> Void) -> Void)?

    // Composer state lives on the view (not the rebuilt subviews), so it survives `rebuild()`:
    // an in-flight post, a typed-but-unsent draft, and the last error all persist across relayouts.
    private var composerDraft = ""
    private var composerError: String?
    private var isPosting = false
    /// The id the draft belongs to, so switching items starts a fresh, empty composer.
    private var composerItemId = ""
    /// The live composer field for the current rebuild; read on submit (Return key / Send click).
    private weak var composerField: NSTextField?

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

    /// A read-only, non-scrolling text view rendering `text` as themed Markdown, sized to fit
    /// `width`. Drop-in for `wrapped(...)`: returns an `NSView` the caller positions by frame.
    private func markdownView(_ text: String, baseFont: NSFont, width: CGFloat) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.textStorage?.setAttributedString(cachedMarkdown(text, baseFont: baseFont))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // flush-left like the NSTextField it replaces
        tv.textContainer?.widthTracksTextView = false
        tv.delegate = linkDelegate
        tv.linkTextAttributes = [
            .foregroundColor: store.theme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        let h = measuredHeight(of: tv, width: width)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: ceil(h))
        return tv
    }

    private func measuredHeight(of tv: NSTextView, width: CGFloat) -> CGFloat {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
        tc.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height)
    }

    private func cachedMarkdown(_ text: String, baseFont: NSFont) -> NSAttributedString {
        if store.theme.key != mdThemeKey { mdCache.removeAll(); mdThemeKey = store.theme.key }
        let key = "\(baseFont.pointSize)\u{1}\(text)"
        if let hit = mdCache[key] { return hit }
        let rendered = renderMarkdown(text, theme: store.theme, baseFont: baseFont)
        mdCache[key] = rendered
        return rendered
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

        // A new item gets a clean composer — don't carry one item's half-typed draft to the next.
        if it.id != composerItemId {
            composerItemId = it.id
            composerDraft = ""; composerError = nil; isPosting = false
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
        let avatar = AvatarView(size: 20, cornerRadius: 10, url: it.authorAvatarURL,
                                placeholderColor: it.authorColor, initials: it.authorInitials,
                                initialsFont: sys(9, .bold), initialsColor: .hex(0x0d0f13),
                                ring: it.isAgent ? it.authorColor : nil)
        avatar.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(avatar)
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
        let bodyText = markdownView(it.body, baseFont: sys(13.5), width: cw - 34)
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
            let av = AvatarView(size: 26, cornerRadius: 13, url: cm.avatarURL,
                                placeholderColor: cm.color, initials: cm.initials,
                                initialsFont: sys(10, .bold), initialsColor: .hex(0x0d0f13),
                                ring: cm.badge == "agent" ? cm.color : nil)
            av.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(av)
            let bubbleW = cw - 37
            let body = markdownView(cm.body, baseFont: sys(12.5), width: bubbleW - 26)
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

        // Composer. The avatar is the signed-in viewer (real image once it loads, initials until
        // then); the field is editable and Send posts the comment. Sized like a comment row above it.
        let cav = AvatarView(size: 26, cornerRadius: 13, url: store.viewer?.avatarURL,
                             placeholderColor: store.viewer?.color ?? Status.dim,
                             initials: store.viewer?.initials ?? "?",
                             initialsFont: sys(10, .bold), initialsColor: .hex(0x0d0f13))
        cav.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(cav)

        let compW = cw - 37
        let comp = BoxView(bg: t.card, radius: 10, border: t.cardbr)
        comp.frame = NSRect(x: padX + 37, y: y, width: compW, height: 38)

        let field = NSTextField(string: composerDraft)
        field.font = sys(12.5)
        field.placeholderString = "Write a comment…"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = t.txt
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.target = self
        field.action = #selector(composerReturn)   // Return submits; fires only on Enter, not on blur
        field.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
        field.isEnabled = !isPosting
        field.frame = NSRect(x: 12, y: 9, width: compW - 84, height: 20)
        comp.addSubview(field)
        composerField = field

        if isPosting {
            let spinner = makeSpinner(size: 14)
            spinner.frame.origin = NSPoint(x: compW - 64 + 21, y: 12); comp.addSubview(spinner)
        } else {
            let send = ClickRow(bg: t.accent, radius: 7)
            send.frame = NSRect(x: compW - 64, y: 7, width: 56, height: 24)
            send.onClick = { [weak self] in self?.submitComposer() }
            let sl = label("Send", sys(11, .semibold), t.onacc, align: .center)
            sl.frame = NSRect(x: 0, y: 4, width: 56, height: 16); send.addSubview(sl)
            comp.addSubview(send)
        }
        doc.addSubview(comp); y += 46

        if let composerError {
            let err = label(composerError, sys(11), Status.red, lines: 0)
            err.preferredMaxLayoutWidth = compW
            err.frame = NSRect(x: padX + 37, y: y, width: compW, height: 30)
            doc.addSubview(err); y += 22
        }
        y += 8

        doc.frame.size.height = y + 10
        scroll.documentView = doc
    }

    /// Post the current composer text. Shared by the Send button and the Return key. No-ops while a
    /// post is in flight or the body is blank; otherwise flips to the posting state and hands the
    /// text to the controller via `onSubmitComment`, which calls back to clear or restore the draft.
    private func submitComposer() {
        guard !isPosting, let onSubmitComment else { return }
        let text = composerField?.stringValue ?? composerDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composerDraft = text
        composerError = nil
        isPosting = true
        needsLayout = true
        onSubmitComment(text) { [weak self] ok, message in
            guard let self else { return }
            self.isPosting = false
            if ok {
                self.composerDraft = ""
                self.composerError = nil
            } else if let message {
                self.composerError = message   // keep the draft so the user can retry
            }
            self.needsLayout = true
        }
    }

    @objc private func composerReturn() { submitComposer() }
}

extension DetailView: NSTextFieldDelegate {
    /// Keep the persisted draft in sync as the user types, so a rebuild (resize, theme, a comment
    /// landing) preserves the in-progress text instead of resetting the field.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === composerField else { return }
        composerDraft = field.stringValue
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
