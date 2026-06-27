import AppKit

/// Scrollable issue/PR detail for the currently-selected item.
final class DetailView: FlippedView {
    let store: Store
    private let scroll = NSScrollView()
    private let linkDelegate = MarkdownLinkDelegate()
    // Memoized Markdown renders so `rebuild()` (run on every `layout()` pass) doesn't re-parse.
    // The parsed blocks are width-independent; only the cheap per-build height measurement uses width.
    private var blocksCache: [String: [MarkdownBlock]] = [:]
    private var mdThemeKey = ""
    /// The item id the scroll offset belongs to. `rebuild()` replaces the document view (which would
    /// reset scrolling to the top); we restore the prior offset while this stays the same item — so a
    /// detail hydrating or the pane resizing doesn't yank the user back up — and let a switch to a
    /// different item start at the top.
    private var lastScrollItemId = ""

    /// Briefly true after the user copies the item's URL, so the id row flashes "Copied ✓" in place
    /// of the copy glyph. Lives on the view (not the rebuilt subviews) so it survives `rebuild()`.
    private var justCopiedURL = false

    /// Called when the user submits a comment. The view hands over the text and a completion the
    /// controller runs on the main actor: `(true, nil)` clears the composer; `(false, message)`
    /// keeps the draft so the user can retry and surfaces `message`.
    var onSubmitComment: ((String, @escaping (Bool, String?) -> Void) -> Void)?

    /// Called when the user clicks the in-pane Refresh button (shown once the detail is loaded, in the
    /// same top-right slot the hydration spinner uses). The controller force-reloads the open item.
    var onRefreshDetail: (() -> Void)?

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

    /// Renders `text` as themed Markdown into a vertical stack of block views sized to fit `width`,
    /// returned in a container the caller positions by frame (its height is set to fit). Text runs
    /// become selectable, link-aware text views; top-level fenced code blocks become padded, copyable
    /// boxes (`codeBlockView`). Most bodies are a single text block, so the common case is one view.
    private func markdownView(_ text: String, baseFont: NSFont, width: CGFloat) -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        let blocks = cachedBlocks(text, baseFont: baseFont)
        var y: CGFloat = 0
        for (i, block) in blocks.enumerated() {
            let v: NSView
            switch block {
            case .text(let attr): v = textBlockView(attr, width: width)
            case .code(let code): v = codeBlockView(code, baseFont: baseFont, width: width)
            }
            v.frame.origin = NSPoint(x: 0, y: y)
            container.addSubview(v)
            y += v.frame.height + (i < blocks.count - 1 ? z(10) : 0)   // gap between stacked blocks
        }
        container.frame.size.height = y
        return container
    }

    /// One Markdown text run (paragraphs/lists/headings/quotes/inline code) as a read-only, selectable
    /// text view with clickable links, sized to fit `width`.
    private func textBlockView(_ attr: NSAttributedString, width: CGFloat) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.textStorage?.setAttributedString(attr)
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

    /// A fenced code block as a padded, rounded box (themed `accentbg2`) holding the code in a
    /// selectable monospaced text view, with a copy button floating in the top-right corner. The code
    /// text is inset on the right by a button-clear gutter so no line slips under the button.
    private func codeBlockView(_ code: String, baseFont: NSFont, width: CGFloat) -> NSView {
        let t = store.theme
        let pad = z(14), vpad = z(11), btnGutter = z(44)
        let box = BoxView(bg: t.accentbg2, radius: z(8), border: t.cardbr)
        let textW = max(z(40), width - pad - btnGutter)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 2
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: textW, height: 10))
        tv.textStorage?.setAttributedString(NSAttributedString(string: code, attributes: [
            .font: monoCodeFont(matching: baseFont),
            .foregroundColor: t.txt,
            .paragraphStyle: para,
        ]))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        let h = ceil(measuredHeight(of: tv, width: textW))
        tv.frame = NSRect(x: pad, y: vpad, width: textW, height: h)
        box.addSubview(tv)
        box.frame = NSRect(x: 0, y: 0, width: width, height: h + vpad * 2)

        let copy = ClickRow(radius: z(6))
        copy.hoverColor = t.hover
        copy.cursor = .pointingHand
        copy.toolTip = "Copy code"
        copy.frame = NSRect(x: width - z(28) - z(8), y: z(7), width: z(28), height: z(22))
        let icon = NSImageView(frame: NSRect(x: z(6), y: z(4), width: z(16), height: z(14)))
        icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        icon.contentTintColor = t.txt4
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown
        copy.addSubview(icon)
        copy.onClick = { [weak self] in self?.copyCode(code, icon: icon) }
        box.addSubview(copy)
        return box
    }

    /// A read-only, *selectable* text view rendering `text` as plain text in `font`/`color`, sized to
    /// fit `width`. Used where the text must be copyable (the title). No Markdown, no link handling;
    /// transparent background.
    private func selectableText(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // flush-left like the NSTextField it replaces
        tv.textContainer?.widthTracksTextView = false
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

    private func cachedBlocks(_ text: String, baseFont: NSFont) -> [MarkdownBlock] {
        if store.theme.key != mdThemeKey { blocksCache.removeAll(); mdThemeKey = store.theme.key }
        let key = "\(baseFont.pointSize)\u{1}\(text)"
        if let hit = blocksCache[key] { return hit }
        let rendered = renderMarkdownBlocks(text, theme: store.theme, baseFont: baseFont)
        blocksCache[key] = rendered
        return rendered
    }

    private func rebuild() {
        let t = store.theme
        layer?.backgroundColor = t.win.cgColor
        let avail = bounds.width
        guard avail > 80 else { scroll.documentView = nil; return }

        let padX: CGFloat = z(26)
        let cw = avail - padX * 2
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: avail, height: 10))
        var y: CGFloat = z(20)

        guard let it = store.selectedItem else {
            let empty = label("Select an item", sys(14), t.txt4)
            empty.frame = NSRect(x: padX, y: z(30), width: cw, height: z(20)); doc.addSubview(empty)
            doc.frame.size.height = z(80); scroll.documentView = doc; lastScrollItemId = ""; return
        }

        // A new item gets a clean composer — don't carry one item's half-typed draft to the next.
        if it.id != composerItemId {
            composerItemId = it.id
            composerDraft = ""; composerError = nil; isPosting = false
        }

        func add(_ v: NSView, x: CGFloat = padX) { v.frame.origin = NSPoint(x: x, y: y); doc.addSubview(v) }

        // A clickable `#id` chip in the header id row: a `color` label that opens `url` on click
        // (no-op when `url` is empty). Returns the x just past it so the caller can place the next
        // element. Used for the plain id and for both ids inside the blocked-by marker.
        func idLink(_ text: String, url: String, color: NSColor, x: CGFloat) -> CGFloat {
            let link = ClickRow(radius: z(4))
            link.hoverColor = t.hover
            if !url.isEmpty {
                link.cursor = .pointingHand
                link.onClick = { [weak self] in self?.openItemURL(url) }
            }
            let w = fitW(text, mono(12))
            link.frame = NSRect(x: x, y: y, width: w + z(6), height: z(20))
            let lbl = label(text, mono(12), color)
            lbl.frame = NSRect(x: z(3), y: z(2), width: w, height: z(16)); link.addSubview(lbl)
            doc.addSubview(link)
            return link.frame.maxX
        }

        // Type row. The kind badge (PR/ISSUE/EPIC) carries the item's *state* color (open green,
        // closed/merged, …) on its text and border — the standalone status label is gone. Its
        // top-right slot now hosts the hydration spinner, so loading never shifts the body down.
        let typeLabel: String = it.epic ? "EPIC" : (it.kind == .pr ? "PR" : "ISSUE")
        let tb = badge(typeLabel, fg: it.statusColor, border: it.statusColor, mono: false)
        tb.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(tb)
        // Repo name (plain), then the current-issue id row. Normally the plain `#id` (accent) opens
        // the item on github.com; under the "By blocked-by" grouping the id is replaced by the
        // dependency marker `⊘ #<blocker> → #<this>` (red, both ids linking to their pages) so the
        // blocker reads right after the repo. A copy-link glyph trails the row.
        let rnX = padX + tb.frame.width + z(10)
        let repoLabel = label(it.repo, mono(12), t.txt3)
        let repoW = fitW(repoLabel)
        repoLabel.frame = NSRect(x: rnX, y: y + z(2), width: repoW, height: z(16)); doc.addSubview(repoLabel)

        var headerRX = rnX + repoW + z(5)
        if let blocked = it.blocked {
            let cross = label("⊘", sys(12), Status.red, align: .center)
            cross.frame = NSRect(x: headerRX, y: y + z(2), width: z(14), height: z(16)); doc.addSubview(cross)
            headerRX = idLink("#\(blocked)", url: "https://github.com/\(it.repo)/issues/\(blocked)",
                              color: Status.red, x: headerRX + z(16))
            let arrow = label("→", sys(12), Status.red)
            arrow.frame = NSRect(x: headerRX + z(1), y: y + z(2), width: z(14), height: z(16)); doc.addSubview(arrow)
            headerRX = idLink(it.num, url: it.url, color: Status.red, x: headerRX + z(19))
        } else {
            headerRX = idLink(it.num, url: it.url, color: t.accent, x: headerRX)
        }
        // Copy-link affordance: a small clickable glyph that copies the item's web URL and flashes
        // "Copied ✓" in place. Sits just past the id/marker, left of the top-right hydration slot.
        if !it.url.isEmpty {
            let copy = ClickRow(radius: z(5))
            copy.hoverColor = t.hover
            copy.cursor = .pointingHand
            copy.onClick = { [weak self] in self?.copyItemURL(it.url) }
            let cx = headerRX + z(4)
            if justCopiedURL {
                let done = label("Copied ✓", mono(11), t.accent)
                let w = fitW(done)
                copy.frame = NSRect(x: cx, y: y, width: w + z(8), height: z(20))
                done.frame = NSRect(x: z(4), y: z(3), width: w, height: z(14)); copy.addSubview(done)
            } else {
                copy.frame = NSRect(x: cx, y: y, width: z(20), height: z(20))
                let glyph = label("⧉", mono(13), t.txt4, align: .center)
                glyph.frame = NSRect(x: 0, y: z(2), width: z(20), height: z(16)); copy.addSubview(glyph)
            }
            doc.addSubview(copy)
        }
        // Top-right slot: while hydrating, a spinner + "Loading details…" (the lead item renders
        // instantly; this signals the body/tasks/comments/checks are still loading and vanishes in
        // place when they land — no vertical shift). Once loaded, a Refresh button in the same slot
        // force-reloads the open item; re-shows this spinner while it reloads.
        if store.isLoadingDetail && store.selectedItemDetail == nil {
            let spinner = makeSpinner(size: z(14))
            spinner.frame.origin = NSPoint(x: padX + cw - z(16), y: y + z(2)); doc.addSubview(spinner)
            let loading = label("Loading details…", sys(11.5), t.txt4, align: .right)
            loading.frame = NSRect(x: padX + cw - z(160), y: y + z(2), width: z(138), height: z(16)); doc.addSubview(loading)
        } else if store.selectedItemDetail != nil {
            let refresh = ClickRow(radius: z(5))
            refresh.hoverColor = t.hover
            refresh.cursor = .pointingHand
            refresh.toolTip = "Refresh"
            refresh.onClick = { [weak self] in self?.onRefreshDetail?() }
            refresh.frame = NSRect(x: padX + cw - z(22), y: y, width: z(22), height: z(20))
            let iv = NSImageView(frame: NSRect(x: z(3), y: z(2), width: z(16), height: z(16)))
            iv.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            iv.contentTintColor = t.txt4
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iv.imageScaling = .scaleProportionallyUpOrDown
            refresh.addSubview(iv)
            doc.addSubview(refresh)
        }
        y += z(30)

        // Title. A selectable (read-only) text view so it can be copied, like the body below.
        let title = selectableText(it.title, font: sys(21, .bold), color: t.txt, width: cw)
        add(title); y += title.frame.height + z(11)

        // Author row.
        let avatar = AvatarView(size: z(20), cornerRadius: z(10), url: it.authorAvatarURL,
                                placeholderColor: it.authorColor, initials: it.authorInitials,
                                initialsFont: sys(9, .bold), initialsColor: .hex(0x0d0f13),
                                ring: it.isAgent ? it.authorColor : nil)
        avatar.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(avatar)
        var rx = padX + z(28)
        let auth = label(it.author, sys(12, .semibold), t.txt2); auth.frame = NSRect(x: rx, y: y + z(3), width: fitW(auth), height: z(16)); doc.addSubview(auth); rx += auth.frame.width + z(9)
        let opened = label("opened \(it.age)", sys(12), t.txt4); opened.frame = NSRect(x: rx, y: y + z(3), width: fitW(opened), height: z(16)); doc.addSubview(opened); rx += opened.frame.width + z(9)
        if let branch = it.branch {
            let b = badge("⎇ \(branch)", fg: t.accent, bg: t.accentbg2)
            b.frame.origin = NSPoint(x: rx, y: y); doc.addSubview(b); rx += b.frame.width + z(9)
        }
        if let a = it.add, let d = it.del {
            let diff = label("+\(a) −\(d)", mono(10.5), t.txt3); diff.frame = NSRect(x: rx, y: y + z(3), width: z(90), height: z(16)); doc.addSubview(diff); rx += z(96)
        }
        y += z(30)

        // Body card.
        let bodyText = markdownView(it.body, baseFont: sys(13.5), width: cw - z(34))
        var cardH = bodyText.frame.height + z(30)
        var taskViews: [NSView] = []
        if !it.tasks.isEmpty {
            cardH += z(20)
            for task in it.tasks {
                let row = FlippedView(frame: NSRect(x: z(17), y: 0, width: cw - z(34), height: z(22)))
                let box = BoxView(bg: task.done ? t.accent : nil, radius: z(4), border: task.done ? t.accent : t.txt4)
                box.frame = NSRect(x: 0, y: z(3), width: z(15), height: z(15))
                if task.done { box.addSubview(centeredGlyph("✓", sys(9, .bold), .hex(0x0d0f13), in: box.frame.size)) }
                row.addSubview(box)
                let tl = label(task.label, sys(12.5), task.done ? t.txt4 : t.txt2)
                tl.frame = NSRect(x: z(24), y: z(3), width: cw - z(34) - z(24), height: z(16)); row.addSubview(tl)
                taskViews.append(row)
                cardH += z(26)
            }
        }
        let card = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
        card.frame = NSRect(x: padX, y: y, width: cw, height: cardH)
        bodyText.frame.origin = NSPoint(x: z(17), y: z(15)); card.addSubview(bodyText)
        var ty = bodyText.frame.maxY + z(13)
        if !taskViews.isEmpty {
            let lbl = label("TASKS", mono(9.5, .semibold), t.txt4); lbl.frame = NSRect(x: z(17), y: ty, width: z(200), height: z(13)); card.addSubview(lbl); ty += z(18)
            for tv in taskViews { tv.frame.origin.y = ty; card.addSubview(tv); ty += z(26) }
        }
        doc.addSubview(card); y += cardH + z(20)

        // PR checks. The ACTIONS header is a disclosure: clicking it toggles the global,
        // persisted collapsed state (`store.prChecksCollapsed`). The X/Y tally stays in the
        // header even when collapsed so the pass summary is always readable.
        if it.kind == .pr && !it.checks.isEmpty {
            let passed = it.checks.filter { $0.statusText == "passed" }.count
            let collapsed = store.prChecksCollapsed
            let header = ClickRow(bg: nil, radius: z(6))
            header.hoverColor = t.hover
            header.frame = NSRect(x: padX, y: y, width: cw, height: z(18))
            header.onClick = { [weak store] in store?.prChecksCollapsed.toggle() }
            // A solid disclosure triangle that rotates with state: ▶ (collapsed) → ▼ (expanded).
            let caret = label(collapsed ? "▶" : "▼", sys(8), t.txt4, align: .center)
            caret.frame = NSRect(x: 0, y: z(4), width: z(14), height: z(12)); header.addSubview(caret)
            let hdr = label("ACTIONS · \(passed)/\(it.checks.count) passing", mono(9.5, .semibold), t.txt4)
            hdr.frame = NSRect(x: z(15), y: z(2), width: cw - z(15), height: z(14)); header.addSubview(hdr)
            doc.addSubview(header); y += z(24)
            if !collapsed {
                let box = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
                let rowH: CGFloat = z(31)
                box.frame = NSRect(x: padX, y: y, width: cw, height: rowH * CGFloat(it.checks.count))
                var cy: CGFloat = 0
                for (i, c) in it.checks.enumerated() {
                    let row = FlippedView(frame: NSRect(x: 0, y: cy, width: cw, height: rowH))
                    let icon = BoxView(bg: .hexA(UInt32(c.color.toHex()), 0.12), radius: z(5), border: c.color)
                    icon.frame = NSRect(x: z(14), y: z(8), width: z(16), height: z(16))
                    icon.addSubview(centeredGlyph(c.icon, sys(9), c.color, in: icon.frame.size)); row.addSubview(icon)
                    let nm = label(c.name, sys(12.5, .medium), t.txt2); nm.frame = NSRect(x: z(40), y: z(7), width: cw - z(220), height: z(16)); row.addSubview(nm)
                    let stt = label(c.statusText, mono(10.5), c.color, align: .right); stt.frame = NSRect(x: cw - z(180), y: z(7), width: z(110), height: z(16)); row.addSubview(stt)
                    let dur = label(c.dur, mono(10), t.txt4, align: .right); dur.frame = NSRect(x: cw - z(62), y: z(7), width: z(48), height: z(16)); row.addSubview(dur)
                    if i < it.checks.count - 1 {
                        let sep = BoxView(bg: t.line); sep.frame = NSRect(x: 0, y: rowH - z(1), width: cw, height: z(1)); row.addSubview(sep)
                    }
                    box.addSubview(row); cy += rowH
                }
                doc.addSubview(box); y += box.frame.height
            }
            y += z(22)
        }

        // PR changed files. Mirrors the ACTIONS disclosure above: the header toggles the global,
        // persisted `store.prFilesCollapsed`, and the count stays visible when collapsed. The list
        // is what a detail fetch hydrated (issues never reach here; a PR with no files renders none).
        if it.kind == .pr && !it.files.isEmpty {
            let collapsed = store.prFilesCollapsed
            let header = ClickRow(bg: nil, radius: z(6))
            header.hoverColor = t.hover
            header.frame = NSRect(x: padX, y: y, width: cw, height: z(18))
            header.onClick = { [weak store] in store?.prFilesCollapsed.toggle() }
            let caret = label(collapsed ? "▶" : "▼", sys(8), t.txt4, align: .center)
            caret.frame = NSRect(x: 0, y: z(4), width: z(14), height: z(12)); header.addSubview(caret)
            let hdr = label("FILES CHANGED · \(it.files.count)", mono(9.5, .semibold), t.txt4)
            hdr.frame = NSRect(x: z(15), y: z(2), width: cw - z(15), height: z(14)); header.addSubview(hdr)
            doc.addSubview(header); y += z(24)
            if !collapsed {
                let box = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
                let rowH: CGFloat = z(31)
                box.frame = NSRect(x: padX, y: y, width: cw, height: rowH * CGFloat(it.files.count))
                var fy: CGFloat = 0
                for (i, f) in it.files.enumerated() {
                    let row = FlippedView(frame: NSRect(x: 0, y: fy, width: cw, height: rowH))
                    let icon = BoxView(bg: .hexA(UInt32(f.color.toHex()), 0.12), radius: z(5), border: f.color)
                    icon.frame = NSRect(x: z(14), y: z(8), width: z(16), height: z(16))
                    icon.addSubview(centeredGlyph(f.glyph, sys(9, .bold), f.color, in: icon.frame.size)); row.addSubview(icon)
                    // Middle-truncate so the filename stays readable when the directory path is long.
                    let nm = label(f.path, mono(11.5), t.txt2); nm.lineBreakMode = .byTruncatingMiddle
                    nm.frame = NSRect(x: z(40), y: z(7), width: cw - z(175), height: z(16)); row.addSubview(nm)
                    let diff = label("+\(f.add) −\(f.del)", mono(10.5), t.txt3, align: .right)
                    diff.frame = NSRect(x: cw - z(130), y: z(7), width: z(116), height: z(16)); row.addSubview(diff)
                    if i < it.files.count - 1 {
                        let sep = BoxView(bg: t.line); sep.frame = NSRect(x: 0, y: rowH - z(1), width: cw, height: z(1)); row.addSubview(sep)
                    }
                    box.addSubview(row); fy += rowH
                }
                doc.addSubview(box); y += box.frame.height
            }
            y += z(22)
        }

        // Comments. The header is a disclosure mirroring ACTIONS/FILES CHANGED: it toggles the
        // global, persisted `store.prCommentsCollapsed`. Only the thread collapses — the composer
        // below stays visible so a comment can always be posted.
        let commentsCollapsed = store.prCommentsCollapsed
        let cHeader = ClickRow(bg: nil, radius: z(6))
        cHeader.hoverColor = t.hover
        cHeader.frame = NSRect(x: padX, y: y, width: cw, height: z(18))
        cHeader.onClick = { [weak store] in store?.prCommentsCollapsed.toggle() }
        let cCaret = label(commentsCollapsed ? "▶" : "▼", sys(8), t.txt4, align: .center)
        cCaret.frame = NSRect(x: 0, y: z(4), width: z(14), height: z(12)); cHeader.addSubview(cCaret)
        let chdr = label("COMMENTS · \(it.comments.count)", mono(9.5, .semibold), t.txt4)
        chdr.frame = NSRect(x: z(15), y: z(2), width: cw - z(15), height: z(14)); cHeader.addSubview(chdr)
        doc.addSubview(cHeader); y += z(24)
        if !commentsCollapsed {
            for cm in it.comments {
                let av = AvatarView(size: z(26), cornerRadius: z(13), url: cm.avatarURL,
                                    placeholderColor: cm.color, initials: cm.initials,
                                    initialsFont: sys(10, .bold), initialsColor: .hex(0x0d0f13),
                                    ring: cm.badge == "agent" ? cm.color : nil)
                av.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(av)
                let bubbleW = cw - z(37)
                let body = markdownView(cm.body, baseFont: sys(12.5), width: bubbleW - z(26))
                let bubbleH = body.frame.height + z(38)
                let bubble = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
                bubble.frame = NSRect(x: padX + z(37), y: y, width: bubbleW, height: bubbleH)
                let an = label(cm.author, sys(12, .bold), t.txt); an.frame = NSRect(x: z(13), y: z(11), width: z(200), height: z(16)); bubble.addSubview(an)
                let tm = label(cm.time, sys(11), t.txt4, align: .right); tm.frame = NSRect(x: bubbleW - z(90), y: z(11), width: z(76), height: z(16)); bubble.addSubview(tm)
                if !cm.badge.isEmpty {
                    let bg = badge(cm.badge, fg: t.accent, border: t.accent); bg.frame.origin = NSPoint(x: z(13) + fitW(an) + z(8), y: z(9)); bubble.addSubview(bg)
                }
                body.frame.origin = NSPoint(x: z(13), y: z(30)); bubble.addSubview(body)
                doc.addSubview(bubble); y += bubbleH + z(13)
            }

            // Composer. The avatar is the signed-in viewer (real image once it loads, initials until
            // then); the field is editable and Send posts the comment. Inside the collapse gate, so
            // collapsing COMMENTS hides the thread and its input together.
            let cav = AvatarView(size: z(26), cornerRadius: z(13), url: store.viewer?.avatarURL,
                                 placeholderColor: store.viewer?.color ?? Status.dim,
                                 initials: store.viewer?.initials ?? "?",
                                 initialsFont: sys(10, .bold), initialsColor: .hex(0x0d0f13))
            cav.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(cav)

            let compW = cw - z(37)
            let comp = BoxView(bg: t.card, radius: z(10), border: t.cardbr)
            comp.frame = NSRect(x: padX + z(37), y: y, width: compW, height: z(38))

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
            field.frame = NSRect(x: z(12), y: z(9), width: compW - z(84), height: z(20))
            comp.addSubview(field)
            composerField = field

            if isPosting {
                let spinner = makeSpinner(size: z(14))
                spinner.frame.origin = NSPoint(x: compW - z(64) + z(21), y: z(12)); comp.addSubview(spinner)
            } else {
                let send = ClickRow(bg: t.accent, radius: z(7))
                send.frame = NSRect(x: compW - z(64), y: z(7), width: z(56), height: z(24))
                send.onClick = { [weak self] in self?.submitComposer() }
                let sl = label("Send", sys(11, .semibold), t.onacc, align: .center)
                sl.frame = NSRect(x: 0, y: z(4), width: z(56), height: z(16)); send.addSubview(sl)
                comp.addSubview(send)
            }
            doc.addSubview(comp); y += z(46)

            if let composerError {
                let err = label(composerError, sys(11), Status.red, lines: 0)
                err.preferredMaxLayoutWidth = compW
                err.frame = NSRect(x: padX + z(37), y: y, width: compW, height: z(30))
                doc.addSubview(err); y += z(22)
            }
        }
        y += z(8)

        doc.frame.size.height = y + z(10)

        // Replacing the document view resets the scroll to the top. Restore the prior offset when
        // we're re-rendering the same item (a detail hydrating, a comment landing, a resize) so the
        // user stays put; only a switch to a different item starts at the top. Clamp to the new
        // content height so a now-shorter document (e.g. the checks section collapsed) can't overscroll.
        let sameItem = it.id == lastScrollItemId
        let priorOrigin = scroll.contentView.bounds.origin
        scroll.documentView = doc
        if sameItem {
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: priorOrigin.x, y: min(priorOrigin.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        lastScrollItemId = it.id
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

    /// Open the selected item's GitHub page in the default browser. Wired to the `#num` anchor link
    /// in the id row.
    private func openItemURL(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Copy a fenced code block's text to the clipboard and briefly swap its button glyph to a
    /// checkmark. Mutates the button icon in place (no relayout), so the confirmation flash isn't lost
    /// to the rebuild a `needsLayout` would trigger; an unrelated rebuild within the window just resets
    /// it early, which is fine for a transient cue.
    private func copyCode(_ code: String, icon: NSImageView) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        icon.contentTintColor = store.theme.accent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak icon] in
            guard let self, let icon else { return }
            icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
            icon.contentTintColor = self.store.theme.txt4
        }
    }

    /// Copy the selected item's web URL to the clipboard and flash a transient "Copied ✓" in the id
    /// row. Mirrors `DeviceFlowSheet.copyCode`: set the flag, relayout to show it, and revert shortly
    /// after unless another copy has moved the state on.
    private func copyItemURL(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        justCopiedURL = true
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.justCopiedURL else { return }
            self.justCopiedURL = false
            self.needsLayout = true
        }
    }
}

extension DetailView: NSTextFieldDelegate {
    /// Keep the persisted draft in sync as the user types, so a rebuild (resize, theme, a comment
    /// landing) preserves the in-progress text instead of resetting the field.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === composerField else { return }
        composerDraft = field.stringValue
    }
}

extension NSColor {
    /// Best-effort RGB hex (used to re-tint check icons).
    func toHex() -> Int {
        guard let c = usingColorSpace(.sRGB) else { return 0x6b7079 }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return (r << 16) | (g << 8) | b
    }
}
