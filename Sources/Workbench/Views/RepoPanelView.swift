import AppKit

final class RepoPanelView: FlippedView {
    let store: Store
    /// Pick a repo to drive the PR/issue lists (owner, name). Wired to the data controller.
    var onSelectRepo: ((String, String) -> Void)?
    /// Open an item's detail by its number. Wired to the data controller.
    var onSelectItem: ((Int) -> Void)?
    /// Open the "manage organizations" sheet (follow/unfollow + reorder).
    var onManageOrgs: (() -> Void)?

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

    private func groupedRow(_ it: Item, indent: CGFloat, width w: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedItemId == it.id
        let row = ClickRow(bg: selected ? t.accentbg : nil, radius: 6)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 8, y: 0, width: w - 16, height: 27)
        row.onClick = { [weak self] in self?.selectItem(it) }
        let cw = w - 16
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
        let prL = label("PRs · \(store.prs.count)", sys(11.5, .semibold), prSel ? t.accent : t.txt3, align: .center)
        prL.frame = NSRect(x: 0, y: 6, width: tabW, height: 16); prTab.addSubview(prL)
        prTab.onClick = { [weak self] in self?.store.tab = .prs }
        addSubview(prTab)

        let isSel = store.tab == .issues
        let isTab = ClickRow(bg: isSel ? t.accentbg2 : t.card, radius: 7)
        isTab.frame = NSRect(x: 14 + tabW + 5, y: y, width: tabW, height: 28)
        let isL = label("Issues · \(store.issues.count)", sys(11.5, .semibold), isSel ? t.accent : t.txt3, align: .center)
        isL.frame = NSRect(x: 0, y: 6, width: tabW, height: 16); isTab.addSubview(isL)
        isTab.onClick = { [weak self] in self?.store.tab = .issues }
        addSubview(isTab)
        y += 38

        // 3. Group-by dropdown.
        let dd = ClickRow(bg: t.card, radius: 8)
        dd.frame = NSRect(x: 12, y: y, width: w - 24, height: 32)
        dd.layer?.borderWidth = 1; dd.layer?.borderColor = t.cardbr.cgColor
        let ic = label("≣", sys(12), t.txt3); ic.frame = NSRect(x: 10, y: 8, width: 16, height: 16); dd.addSubview(ic)
        let ddl = label("View: \(store.groupBy.rawValue)", sys(12, .semibold), t.txt)
        ddl.frame = NSRect(x: 30, y: 8, width: w - 24 - 60, height: 16); dd.addSubview(ddl)
        let car = label("▾", sys(10), t.txt4, align: .right); car.frame = NSRect(x: w - 24 - 24, y: 8, width: 14, height: 16); dd.addSubview(car)
        dd.onClick = { [weak self] in self?.store.viewMenuOpen.toggle() }
        addSubview(dd)
        let listTop = y + 42

        // 4. List body.
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: listTop, width: w, height: bounds.height - listTop - 8))
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: 10))
        var ly: CGFloat = 6
        let items = store.listItems
        if store.isLoadingItems && items.isEmpty {
            // First load of this repo's items: a spinner where the cards will appear.
            let spinner = makeSpinner()
            spinner.frame.origin = NSPoint(x: (w - 20) / 2, y: 16); doc.addSubview(spinner)
            ly += 52
        } else if store.groupBy == .none {
            for it in items {
                let c = itemCard(it, width: w, t: t)
                c.frame.origin.y = ly; doc.addSubview(c); ly += 58
            }
        } else {
            // Grouped tree: parents first, then children indented.
            let parents = items.filter { $0.parent == nil }
            for p in parents {
                let r = groupedRow(p, indent: 0, width: w, t: t)
                r.frame.origin.y = ly; doc.addSubview(r); ly += 29
                for child in items where child.parent == p.id {
                    let cr = groupedRow(child, indent: 18, width: w, t: t)
                    cr.frame.origin.y = ly; doc.addSubview(cr); ly += 29
                }
            }
        }
        doc.frame.size.height = max(ly, listScroll.frame.height)
        listScroll.documentView = doc
        addSubview(listScroll)

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
                row.onClick = { [weak self] in self?.store.groupBy = g; self?.store.viewMenuOpen = false }
                menu.addSubview(row); my += 36
            }
            addSubview(menu)
        }
    }
}
