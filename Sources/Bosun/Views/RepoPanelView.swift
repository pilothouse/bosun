import AppKit
import Domain

final class RepoPanelView: FlippedView {
    let store: Store
    /// Pick a repo to drive the PR/issue lists (owner, name). Wired to the data controller.
    var onSelectRepo: ((String, String) -> Void)?
    /// Open an item's detail by its number. Wired to the data controller.
    var onSelectItem: ((Int) -> Void)?
    /// Open the "manage organizations" sheet (follow/unfollow + reorder).
    var onManageOrgs: (() -> Void)?
    /// The status filter changed — ask the data controller to re-fetch the current repo in the new
    /// scope. Wired to the data controller.
    var onChangeFilter: (() -> Void)?
    /// The grouping ("View") changed — lets the data controller lazily fetch blocked-by data the
    /// first time the user enters "By blocked-by". Wired to the data controller.
    var onChangeGroup: (() -> Void)?

    /// The item the list was last auto-scrolled to, so we focus the open item once when the
    /// selection changes (e.g. restored on launch) without fighting the user's manual scrolling.
    private var focusedItemId: String?

    /// The list's scroll view, retained so its offset can be preserved across rebuilds: opening an
    /// item hydrates its detail, which repaints the whole panel — without this the list would jump
    /// back to the top on every such repaint (and on every background refresh).
    private weak var listScroll: NSScrollView?
    /// Identity of the list currently shown (repo + tab + grouping + status filter). When it changes
    /// the list is a different list, so the scroll resets to the top; otherwise the prior offset is
    /// restored across the repaint.
    private var listIdentity = ""

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }
    override func layout() { super.layout(); rebuild() }

    /// Highlight the row immediately, then ask the data controller to hydrate its detail.
    private func selectItem(_ it: Item) {
        store.selectedItemId = it.id
        if let number = Int(it.id) { onSelectItem?(number) }
    }

    /// Collapse or expand a grouped row's subtree (the store change triggers a rebuild).
    private func toggleCollapse(_ id: String) {
        if store.collapsedItems.contains(id) { store.collapsedItems.remove(id) }
        else { store.collapsedItems.insert(id) }
    }

    /// What the orgs region shows before any live data loads: a sign-in prompt when signed out,
    /// the fetch error when one occurred, otherwise the genuinely-empty result.
    private func orgsEmptyHint() -> String {
        if let error = store.dataError { return error }
        if case .signedIn = store.authState {
            // Signed in with orgs available, but the user has hidden them all via "manage".
            if !store.orgs.isEmpty { return "All organizations are hidden. Tap “manage” to show some." }
            return "No organizations for this account."
        }
        return "Sign in to GitHub to load your organizations and repositories."
    }

    // MARK: builders

    private func orgRows(width w: CGFloat, t: Theme) -> (FlippedView, CGFloat) {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: 10))
        var y: CGFloat = 0
        let head = FlippedView(frame: NSRect(x: 0, y: y, width: w, height: 30))
        let hl = label("ORGANIZATIONS", mono(9.5, .semibold), t.txt4)
        hl.frame = NSRect(x: 14, y: 9, width: 160, height: 14); head.addSubview(hl)
        // The "manage" link opens the follow/unfollow + reorder sheet.
        let manage = ClickRow(bg: nil, radius: 5)
        manage.hoverColor = t.hover
        manage.frame = NSRect(x: w - 78, y: 4, width: 66, height: 24)
        manage.onClick = { [weak self] in self?.onManageOrgs?() }
        let manageLabel = label("manage", sys(11, .semibold), t.accent, align: .right)
        manageLabel.frame = NSRect(x: 0, y: 5, width: 58, height: 14); manage.addSubview(manageLabel)
        head.addSubview(manage)
        doc.addSubview(head); y += 30

        let orgs = store.visibleOrgs
        if orgs.isEmpty {
            // First load: show a spinner; only fall back to the text hint once the fetch settles.
            if store.isLoadingOrgs {
                let spinner = makeSpinner(size: 18)
                spinner.frame.origin = NSPoint(x: 14, y: y + 6); doc.addSubview(spinner)
            } else {
                let hint = label(orgsEmptyHint(), sys(11.5), t.txt4, lines: 0)
                hint.frame = NSRect(x: 14, y: y + 4, width: w - 28, height: 34); doc.addSubview(hint)
            }
            doc.frame.size.height = y + 44
            return (doc, y + 44)
        }

        for org in orgs {
            let expanded = store.expandedOrgs.contains(org.id)
            let row = ClickRow(bg: nil)
            row.hoverColor = t.hover
            row.frame = NSRect(x: 0, y: y, width: w, height: 36)
            row.onClick = { [weak self] in
                guard let self else { return }
                if self.store.expandedOrgs.contains(org.id) { self.store.expandedOrgs.remove(org.id) }
                else { self.store.expandedOrgs.insert(org.id) }
            }
            let sq = AvatarView(size: 22, cornerRadius: 6, url: org.avatarURL,
                                placeholderColor: org.color,
                                initials: String(org.name.prefix(2)).uppercased(),
                                initialsFont: sys(9, .bold), initialsColor: .white)
            sq.frame = NSRect(x: 14, y: 7, width: 22, height: 22)
            row.addSubview(sq)
            let nm = label(org.name, sys(12.5, .semibold), t.txt)
            nm.frame = NSRect(x: 46, y: 9, width: w - 46 - 60, height: 18); row.addSubview(nm)
            let rc = label("\(org.repos.count)", mono(10), t.txt4, align: .right)
            rc.frame = NSRect(x: w - 56, y: 9, width: 24, height: 18); row.addSubview(rc)
            let caret = label(expanded ? "▾" : "▸", sys(10), t.txt4, align: .center)
            caret.frame = NSRect(x: w - 26, y: 9, width: 12, height: 18); row.addSubview(caret)
            doc.addSubview(row); y += 36

            if expanded {
                for rp in org.repos {
                    let selectedRepo = store.selectedRepoKey == "\(rp.owner)/\(rp.name)"
                    let rr = ClickRow(bg: selectedRepo ? t.accentbg : nil, radius: 6)
                    rr.hoverColor = t.hover
                    rr.frame = NSRect(x: 0, y: y, width: w, height: 28)
                    rr.onClick = { [weak self] in self?.onSelectRepo?(rp.owner, rp.name) }
                    let g = label("◇", sys(10), selectedRepo ? t.accent : t.txt4)
                    g.frame = NSRect(x: 30, y: 6, width: 12, height: 16); rr.addSubview(g)
                    let rn = label(rp.name, sys(12), selectedRepo ? t.txt : t.txt2)
                    rn.frame = NSRect(x: 46, y: 5, width: w - 46 - 50, height: 16); rr.addSubview(rn)
                    let open = BoxView(bg: t.accentbg2, radius: 9)
                    let ow = label("\(rp.open)", sys(9.5, .semibold), t.accent, align: .center)
                    let oww = max(20, ow.intrinsicContentSize.width + 12)
                    open.frame = NSRect(x: w - oww - 14, y: 6, width: oww, height: 16)
                    ow.frame = open.bounds; open.addSubview(ow); rr.addSubview(open)
                    doc.addSubview(rr); y += 28
                }
                y += 4
            }
        }
        doc.frame.size.height = y
        return (doc, y)
    }

    private func itemCard(_ it: Item, width w: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedItemId == it.id
        let card = ClickRow(bg: t.card, radius: 9)
        card.hoverColor = t.hover
        card.frame = NSRect(x: 10, y: 0, width: w - 20, height: 52)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (selected ? t.accent : t.cardbr).cgColor
        card.onClick = { [weak self] in self?.selectItem(it) }
        let cw = w - 20

        let dot = Dot(it.dotColor, 8, radius: 4)
        dot.frame.origin = NSPoint(x: 10, y: 10); card.addSubview(dot)
        let num = label(it.num, mono(11), t.txt3)
        num.frame = NSRect(x: 24, y: 8, width: 36, height: 14); card.addSubview(num)
        let title = label(it.title, sys(12.5, .medium), t.txt)
        title.frame = NSRect(x: 62, y: 8, width: cw - 62 - 70, height: 14); card.addSubview(title)
        let st = label(it.statusLabel, sys(10, .semibold), it.statusColor, align: .right)
        st.frame = NSRect(x: cw - 76, y: 8, width: 70, height: 14); card.addSubview(st)

        let ml = label(it.metaLeft, mono(10), t.txt4)
        ml.frame = NSRect(x: 25, y: 28, width: cw / 2, height: 14); card.addSubview(ml)
        let mr = label(it.metaRight, mono(10), it.agentColor, align: .right)
        mr.frame = NSRect(x: cw - 110, y: 28, width: 104, height: 14); card.addSubview(mr)
        return card
    }

    private func groupedRow(_ it: Item, indent: CGFloat, hasChildren: Bool,
                            width w: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedItemId == it.id
        let row = ClickRow(bg: selected ? t.accentbg : nil, radius: 6)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 8, y: 0, width: w - 16, height: 27)
        row.onClick = { [weak self] in self?.selectItem(it) }
        let cw = w - 16
        // A disclosure caret sits in the indent gutter (left of the glyph) for rows with children;
        // it's a nested ClickRow so clicking it toggles collapse instead of selecting the row.
        if hasChildren {
            let collapsed = store.collapsedItems.contains(it.id)
            let caret = ClickRow(bg: nil, radius: 4)
            caret.hoverColor = t.hover
            caret.frame = NSRect(x: indent, y: 3, width: 14, height: 21)
            caret.onClick = { [weak self] in self?.toggleCollapse(it.id) }
            let cl = label(collapsed ? "▸" : "▾", sys(9), t.txt4, align: .center)
            cl.frame = NSRect(x: 0, y: 5, width: 14, height: 12); caret.addSubview(cl)
            row.addSubview(caret)
        }
        let g = label(it.glyph, sys(11), it.gcolor, align: .center)
        g.frame = NSRect(x: indent + 14, y: 6, width: 14, height: 14); row.addSubview(g)
        let num = label(it.num, mono(11), t.txt3)
        num.frame = NSRect(x: indent + 32, y: 6, width: 34, height: 14); row.addSubview(num)
        let title = label(it.title, sys(12), selected ? t.txt : t.txt2)
        title.frame = NSRect(x: indent + 68, y: 6, width: cw - indent - 68 - 22, height: 14); row.addSubview(title)
        if it.blocked != nil {
            let b = label("⊘", sys(10), Status.red, align: .center)
            b.frame = NSRect(x: cw - 20, y: 6, width: 14, height: 14); row.addSubview(b)
        }
        return row
    }

    // MARK: layout

    private func rebuild() {
        // Capture the list's scroll position before tearing the panel down, so a plain repaint
        // (e.g. opening an item, which hydrates its detail) can restore it instead of jumping to top.
        let priorListOffset = listScroll?.contentView.bounds.origin
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = t.panel.cgColor
        let w = bounds.width
        guard w > 60 else { return }

        let lb = BoxView(bg: t.line)
        lb.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height); addSubview(lb)

        // 1. Orgs (scroll region; design caps it at max-height 268, shrinking to fit content).
        let (orgsDoc, orgsContentH) = orgRows(width: w, t: t)
        let orgsH: CGFloat = min(orgsContentH, 268)
        let orgsScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: orgsH))
        orgsScroll.drawsBackground = false
        orgsScroll.hasVerticalScroller = true
        orgsScroll.autohidesScrollers = true
        orgsDoc.frame.size.width = w
        orgsScroll.documentView = orgsDoc
        addSubview(orgsScroll)
        let ob = BoxView(bg: t.line)
        ob.frame = NSRect(x: 0, y: orgsH, width: w, height: 1); addSubview(ob)

        // 2. Repo header + tabs.
        var y = orgsH + 12
        let repoTitle = label(store.selectedRepoTitle.isEmpty ? "No repository" : store.selectedRepoTitle,
                              sys(13, .bold), store.selectedRepoTitle.isEmpty ? t.txt4 : t.txt)
        repoTitle.frame = NSRect(x: 14, y: y, width: w - 28, height: 18); addSubview(repoTitle)
        y += 30

        let tabW = (w - 28 - 5) / 2
        let prSel = store.tab == .prs
        let prTab = ClickRow(bg: prSel ? t.accentbg2 : t.card, radius: 7)
        prTab.frame = NSRect(x: 14, y: y, width: tabW, height: 28)
        let prL = label("PRs · \(store.visiblePRs.count)", sys(11.5, .semibold), prSel ? t.accent : t.txt3, align: .center)
        prL.frame = NSRect(x: 0, y: 6, width: tabW, height: 16); prTab.addSubview(prL)
        prTab.onClick = { [weak self] in self?.store.tab = .prs }
        addSubview(prTab)

        let isSel = store.tab == .issues
        let isTab = ClickRow(bg: isSel ? t.accentbg2 : t.card, radius: 7)
        isTab.frame = NSRect(x: 14 + tabW + 5, y: y, width: tabW, height: 28)
        let isL = label("Issues · \(store.visibleIssues.count)", sys(11.5, .semibold), isSel ? t.accent : t.txt3, align: .center)
        isL.frame = NSRect(x: 0, y: 6, width: tabW, height: 16); isTab.addSubview(isL)
        isTab.onClick = { [weak self] in self?.store.tab = .issues }
        addSubview(isTab)
        y += 38

        // 3. View-options row: the group-by dropdown (left) and the status filter (right) share it.
        let gap: CGFloat = 6
        let halfW = (w - 24 - gap) / 2
        let statusX = 12 + halfW + gap
        addSubview(dropdownButton(x: 12, y: y, width: halfW, t: t, icon: "≣",
                                  text: "View: \(store.groupBy.rawValue)") { [weak self] in
            guard let self else { return }
            self.store.statusMenuOpen = false
            self.store.viewMenuOpen.toggle()
        })
        addSubview(dropdownButton(x: statusX, y: y, width: halfW, t: t, icon: "⚑",
                                  text: statusSummary()) { [weak self] in
            guard let self else { return }
            self.store.viewMenuOpen = false
            self.store.statusMenuOpen.toggle()
        })
        // Publish the regions where a click must NOT dismiss the dropdown — the two toggle buttons
        // and whichever menu is open — in window coords, for the window's `sendEvent` to consult.
        if store.viewMenuOpen || store.statusMenuOpen {
            var rects = [NSRect(x: 12, y: y, width: halfW, height: 32),
                         NSRect(x: statusX, y: y, width: halfW, height: 32)]
            if store.viewMenuOpen {
                rects.append(NSRect(x: 12, y: y + 36, width: w - 24,
                                    height: CGFloat(Store.GroupBy.allCases.count) * 36 + 10))
            }
            if store.statusMenuOpen {
                rects.append(NSRect(x: statusX, y: y + 36, width: halfW,
                                    height: CGFloat(statusOptions.count) * 36 + 10))
            }
            store.menuDismissRects = rects.map { convert($0, to: nil) }
        } else {
            store.menuDismissRects = []
        }
        let listTop = y + 42

        // 4. List body.
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: listTop, width: w, height: bounds.height - listTop - 8))
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: 10))
        var ly: CGFloat = 6
        var selectedRect: NSRect?   // the open item's card, captured so we can scroll it into view
        let items = store.listItems
        if store.isLoadingItems && items.isEmpty {
            // First load of this repo's items: a spinner where the cards will appear.
            let spinner = makeSpinner()
            spinner.frame.origin = NSPoint(x: (w - 20) / 2, y: 16); doc.addSubview(spinner)
            ly += 52
        } else if store.groupBy == .none {
            for it in items {
                let c = itemCard(it, width: w, t: t)
                c.frame.origin.y = ly; doc.addSubview(c)
                if it.id == store.selectedItemId { selectedRect = c.frame }
                ly += 58
            }
        } else {
            // Grouped tree: nest by the active mode's relationship — sub-issue parent ("By parent")
            // or first blocker ("By blocked-by") — honoring collapse. The pure `GitHubItemTree`
            // rule keeps roots/siblings in list order, treats an item whose related item isn't in
            // view as a root, and guards cycles.
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let parentOf: [String: String] = items.reduce(into: [:]) { map, it in
                if let key = store.groupBy == .blocked ? it.blocked : it.parent { map[it.id] = key }
            }
            let rows = GitHubItemTree.rows(order: items.map(\.id), parentOf: parentOf,
                                           collapsed: store.collapsedItems)
            for r in rows {
                guard let it = byId[r.id] else { continue }
                let gr = groupedRow(it, indent: CGFloat(r.depth) * 18, hasChildren: r.hasChildren,
                                    width: w, t: t)
                gr.frame.origin.y = ly; doc.addSubview(gr)
                if it.id == store.selectedItemId { selectedRect = gr.frame }
                ly += 29
            }
        }
        // When the closed/merged history was bounded, say so rather than implying the list is complete.
        if store.listTruncated && !(store.isLoadingItems && items.isEmpty) {
            let note = label("Showing newest \(GitHubItemStates.historyCap) — older closed items not loaded.",
                             sys(10.5), t.txt4, lines: 2)
            note.frame = NSRect(x: 14, y: ly + 4, width: w - 28, height: 30); doc.addSubview(note)
            ly += 38
        }
        doc.frame.size.height = max(ly, listScroll.frame.height)
        listScroll.documentView = doc
        addSubview(listScroll)
        self.listScroll = listScroll

        // Preserve the user's place across a plain repaint; reset to the top only when the list
        // itself changed (repo/tab/grouping/status-filter switch). The selection-focus below can
        // still override this to bring a newly-opened item into view.
        let identity = [store.selectedRepoKey ?? "", store.tab.rawValue, store.groupBy.storageKey,
                        store.prStates.map(\.rawValue).sorted().joined(separator: ","),
                        store.issueStates.map(\.rawValue).sorted().joined(separator: ",")]
            .joined(separator: "|")
        if identity == listIdentity, let off = priorListOffset {
            // Clamp to the new content height in case the list shrank, so we never land in empty space.
            let maxY = max(0, doc.frame.height - listScroll.contentView.bounds.height)
            listScroll.contentView.scroll(to: NSPoint(x: off.x, y: min(off.y, maxY)))
            listScroll.reflectScrolledClipView(listScroll.contentView)
        }
        listIdentity = identity

        // Focus the open item: scroll it into view once when the selection changes (e.g. restored on
        // launch, or switched to its tab), but never on a plain repaint — so manual scrolling sticks.
        if store.selectedItemId.isEmpty {
            focusedItemId = nil
        } else if let rect = selectedRect, store.selectedItemId != focusedItemId {
            focusedItemId = store.selectedItemId
            DispatchQueue.main.async { [weak doc] in doc?.scrollToVisible(rect.insetBy(dx: 0, dy: -28)) }
        }

        // Dropdown overlay.
        if store.viewMenuOpen {
            let menu = BoxView(bg: t.panel, radius: 10, border: t.line2)
            let mh = CGFloat(Store.GroupBy.allCases.count) * 36 + 10
            menu.frame = NSRect(x: 12, y: y + 36, width: w - 24, height: mh)
            menu.layer?.shadowColor = NSColor.black.cgColor
            menu.layer?.shadowOpacity = 0.45
            menu.layer?.shadowRadius = 16
            menu.layer?.shadowOffset = CGSize(width: 0, height: -6)
            menu.layer?.masksToBounds = false
            var my: CGFloat = 5
            for g in Store.GroupBy.allCases {
                let on = store.groupBy == g
                let row = ClickRow(bg: on ? t.accentbg : nil, radius: 7)
                row.hoverColor = t.hover
                row.frame = NSRect(x: 5, y: my, width: w - 24 - 10, height: 34)
                let chk = label(on ? "✓" : "", sys(11), t.accent); chk.frame = NSRect(x: 10, y: 9, width: 14, height: 16); row.addSubview(chk)
                let gl = label(g.rawValue, sys(12.5), t.txt); gl.frame = NSRect(x: 30, y: 9, width: 160, height: 16); row.addSubview(gl)
                row.onClick = { [weak self] in
                    self?.store.groupBy = g
                    self?.store.viewMenuOpen = false
                    self?.onChangeGroup?()   // lazily load blocked-by data on first entering that mode
                }
                menu.addSubview(row); my += 36
            }
            addSubview(menu)
        }

        // Status filter overlay — a multi-check menu of the active tab's states (Open/Closed, plus
        // Merged for PRs). Toggling keeps the menu open so several states can be flipped at once.
        if store.statusMenuOpen {
            let options = statusOptions
            let selected = store.tab == .prs ? store.prStates : store.issueStates
            let menu = BoxView(bg: t.panel, radius: 10, border: t.line2)
            let mh = CGFloat(options.count) * 36 + 10
            menu.frame = NSRect(x: statusX, y: y + 36, width: halfW, height: mh)
            menu.layer?.shadowColor = NSColor.black.cgColor
            menu.layer?.shadowOpacity = 0.45
            menu.layer?.shadowRadius = 16
            menu.layer?.shadowOffset = CGSize(width: 0, height: -6)
            menu.layer?.masksToBounds = false
            var my: CGFloat = 5
            for state in options {
                let on = selected.contains(state)
                let row = ClickRow(bg: on ? t.accentbg : nil, radius: 7)
                row.hoverColor = t.hover
                row.frame = NSRect(x: 5, y: my, width: halfW - 10, height: 34)
                let chk = label(on ? "✓" : "", sys(11), t.accent); chk.frame = NSRect(x: 10, y: 9, width: 14, height: 16); row.addSubview(chk)
                let gl = label(Self.stateName(state), sys(12.5), t.txt); gl.frame = NSRect(x: 30, y: 9, width: halfW - 40, height: 16); row.addSubview(gl)
                row.onClick = { [weak self] in self?.toggleStatus(state) }
                menu.addSubview(row); my += 36
            }
            addSubview(menu)
        }
    }

    /// The lifecycle states the status filter offers for the active tab — issues have no `merged`.
    private var statusOptions: [GitHubItemState] {
        store.tab == .prs ? [.open, .closed, .merged] : [.open, .closed]
    }

    /// A compact label for the status button: the first selected state plus a `+N` for the rest,
    /// in the menu's canonical order (e.g. "Open +1").
    private func statusSummary() -> String {
        let selected = store.tab == .prs ? store.prStates : store.issueStates
        let ordered = statusOptions.filter(selected.contains)
        guard let first = ordered.first else { return "None" }
        return ordered.count > 1 ? "\(Self.stateName(first)) +\(ordered.count - 1)" : Self.stateName(first)
    }

    private static func stateName(_ state: GitHubItemState) -> String {
        switch state {
        case .open: "Open"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }

    /// Flip one state in the active tab's selection, then re-fetch in the new scope. Never empties
    /// the set — unchecking the last remaining state is a no-op, so the list can't go blank.
    private func toggleStatus(_ state: GitHubItemState) {
        let isPR = store.tab == .prs
        var set = isPR ? store.prStates : store.issueStates
        if set.contains(state) {
            guard set.count > 1 else { return }
            set.remove(state)
        } else {
            set.insert(state)
        }
        if isPR { store.prStates = set } else { store.issueStates = set }
        onChangeFilter?()
    }

    /// A bordered dropdown button shared by the View and Status controls: an icon, a label, and a
    /// caret. `onClick` opens its menu.
    private func dropdownButton(x: CGFloat, y: CGFloat, width: CGFloat, t: Theme,
                                icon: String, text: String, onClick: @escaping () -> Void) -> ClickRow {
        let dd = ClickRow(bg: t.card, radius: 8)
        dd.frame = NSRect(x: x, y: y, width: width, height: 32)
        dd.layer?.borderWidth = 1; dd.layer?.borderColor = t.cardbr.cgColor
        let ic = label(icon, sys(12), t.txt3); ic.frame = NSRect(x: 10, y: 8, width: 16, height: 16); dd.addSubview(ic)
        let l = label(text, sys(12, .semibold), t.txt)   // lines: 1 → already truncates with a tail
        l.frame = NSRect(x: 30, y: 8, width: width - 30 - 22, height: 16); dd.addSubview(l)
        let car = label("▾", sys(10), t.txt4, align: .right); car.frame = NSRect(x: width - 22, y: 8, width: 14, height: 16); dd.addSubview(car)
        dd.onClick = onClick
        return dd
    }
}
