import AppKit
import Domain

final class RepoPanelView: FlippedView {
    let store: Store
    /// Pick a repo to drive the PR/issue lists (owner, name). Wired to the data controller.
    var onSelectRepo: ((String, String) -> Void)?
    /// Pick a whole org: aggregate every repo's PRs/issues into per-repo sections. Wired to the
    /// data controller (which also clears the repo selection and expands the org).
    var onSelectOrg: ((String) -> Void)?
    /// Open an item's detail. Passes the whole item so the controller can route the detail fetch to
    /// the item's own repo (the aggregate org list mixes repos). Wired to the data controller.
    var onSelectItem: ((Item) -> Void)?
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
    /// The orgs/repos scroll view, retained for the same reason as `listScroll`: selecting an
    /// org/repo or a background refresh repaints the whole panel, which would otherwise snap this
    /// list back to the top. Its offset is preserved across rebuilds.
    private weak var orgsScroll: NSScrollView?
    /// One-shot guard for the *cross-launch* orgs-scroll restore: the persisted offset is applied on
    /// the first rebuild that actually has orgs (so the content is tall enough to honor it), after
    /// which live preservation takes over. Without this, the empty "loading" render would set a live
    /// offset of 0 and the saved position would be lost.
    private var restoredOrgsScroll = false
    /// The bounds-change observer on the orgs clip view, so the user's scroll is mirrored into
    /// `store.orgsScrollOffset` for persistence. Recreated each rebuild (the scroll view is), so the
    /// previous one is torn down first to avoid stacking observers.
    private var orgsScrollObserver: NSObjectProtocol?
    /// Identity of the list currently shown (repo + tab + grouping + status filter). When it changes
    /// the list is a different list, so the scroll resets to the top; otherwise the prior offset is
    /// restored across the repaint.
    private var listIdentity = ""

    /// Cached issue/PR list document, reused across rebuilds when the list's *content* is unchanged
    /// (see `installListDoc`). `rebuild()` runs on every `layout()` — so ~60×/sec while the orgs↔issues
    /// divider is dragged, and once per store change (e.g. expanding an org). Building the list eagerly
    /// materializes one card view per item (~1000 `NSTextField`s + per-row `fitW()` measurement for a
    /// few-hundred-item repo), which is the drag lag (#91). A *strong* ref keeps the built document
    /// alive through `rebuild()`'s teardown so it can be reparented into the fresh scroll view — the
    /// same reparent `repopulateList()` already relies on. `cachedListContentH` is the doc's natural
    /// (content) height, kept so the reused doc can be re-stretched to fill a resized viewport.
    private var cachedListDoc: FlippedView?
    private var cachedListSig: Int?
    private var cachedListContentH: CGFloat = 0
    /// Cached orgs document, reused across rebuilds when the orgs' content is unchanged — the same
    /// scheme as `cachedListDoc`. During a divider drag only `store.orgsListHeight` changes (not in the
    /// signature), so this is reused every frame; expanding/collapsing an org changes the signature so
    /// it rebuilds once. Reusing it also avoids the `AvatarView` initials-flash on relayout.
    private var cachedOrgsDoc: FlippedView?
    private var cachedOrgsSig: Int?
    private var cachedOrgsContentH: CGFloat = 0

    /// Live free-text filter over the loaded issues/PRs (title / number / labels). Like the rail's
    /// "Search connections" field (`ConnectionRailView`), the query is panel-local transient state,
    /// deliberately *not* in `Store`: a `store.notify()` per keystroke would tear the whole panel down
    /// and drop the field's focus mid-type. Typing instead rebuilds only the list document below the
    /// (sibling) field via `repopulateList()`, so the field keeps its focus and insertion point.
    private var searchQuery = ""
    private weak var searchField: NSTextField?

    /// The draggable splitter on the orgs↔issues seam (#91). Reuses the detail↔terminal divider
    /// machinery (`DragHandle` + `SplitLayout`). `DragHandle` owns its gesture via a tracking loop,
    /// so the drag survives this panel's full teardown/rebuild on every `layout()`; the handle is a
    /// persistent property kept out of the teardown only to avoid recreating it each rebuild.
    private let orgsHandle = DragHandle()
    /// The orgs cap captured at drag start, held for the gesture. Starting from the cap (not the
    /// displayed height) means a downward drag can't accidentally shrink a cap that already exceeds
    /// the content — so the saved preference is never corrupted in the few-orgs case.
    private var orgsDragStartCap: CGFloat = 268

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        orgsHandle.axis = .vertical
        orgsHandle.onBegin = { [weak self] in
            guard let self else { return }
            self.orgsDragStartCap = self.store.orgsListHeight
        }
        orgsHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            // Orgs is the top pane and the grip sits on its bottom edge, so dragging down — a
            // negative window-space delta (y-up) — grows it; hence `- delta`. `clampExtent` keeps
            // the orgs region above its floor and the list/chrome below above theirs (#91).
            let newCap = Double(self.orgsDragStartCap - delta)
            self.store.orgsListHeight = CGFloat(SplitLayout.clampExtent(
                newCap, total: Double(self.bounds.height),
                minTerminal: SplitLayout.minOrgsListHeight,
                minDetail: Double(self.orgsBottomReserve)))
            self.needsLayout = true
        }
        // Persist the final cap once the drag ends, not on every frame (mirrors the terminal divider).
        orgsHandle.onEnd = { [weak self] in self?.store.persist() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The vertical space the orgs cap must always leave below its seam: the fixed header/tabs/
    /// search/controls chrome accumulated between the seam and the list in `rebuild()`, the list's
    /// bottom padding, and a few list rows so the list can never be squeezed shut. Keep the literals
    /// in sync with the `y +=` accumulation in `rebuild()`.
    private var orgsBottomReserve: CGFloat {
        z(12) + z(30) + z(38) + z(42) + z(42) + z(8) + z(160)
    }

    /// Position the persistent splitter on the orgs seam: a fat, seam-centered hit-zone (above all
    /// panes so a press near the seam from either side starts a drag, #84) with a thin centered grip
    /// pill. Re-adding it reorders it to front. Mirrors `CenterColumnView.layout()`.
    private func layoutOrgsHandle(seamY: CGFloat, width w: CGFloat, t: Theme) {
        let gripT: CGFloat = z(14)
        orgsHandle.frame = NSRect(x: 0, y: seamY - gripT / 2, width: w, height: gripT)
        let grip = BoxView(bg: t.txt5, radius: z(1.5))
        grip.frame = NSRect(x: (w - z(34)) / 2, y: (gripT - z(3)) / 2, width: z(34), height: z(3))
        orgsHandle.subviews.forEach { $0.removeFromSuperview() }
        orgsHandle.addSubview(grip)
        addSubview(orgsHandle)   // reorder to front so the seam-centered hit-zone wins (#84)
        window?.invalidateCursorRects(for: orgsHandle)
    }

    func apply() { needsLayout = true }
    override func layout() { super.layout(); rebuild() }

    // The panel itself takes keyboard focus (never a row) so arrow navigation survives `rebuild()`,
    // which recreates every subview on each selection change but never the panel object. When the
    // terminal or the search field's editor is first responder instead, they receive keys — so
    // arrows only drive the list once the user has clicked into it.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 125: moveSelection(by: 1)      // Down arrow → next visible item
        case 126: moveSelection(by: -1)     // Up arrow → previous visible item
        default:  super.keyDown(with: e)    // let everything else flow up the responder chain
        }
    }

    /// Move the selection by one visible row (clamped, no wrap), then select it — scrolling it into
    /// view and opening its detail, exactly as a click would. Reads `visibleListRows()` so it honors
    /// the live search / grouping / collapse / org sectioning. With nothing selected (or the selection
    /// filtered or collapsed out of view), Down selects the first visible item and Up the last.
    private func moveSelection(by delta: Int) {
        let items = visibleListRows().compactMap { $0.item }
        guard !items.isEmpty else { return }
        let target: Int
        if let cur = items.firstIndex(where: { $0.id == store.selectedItemId }) {
            let next = min(max(cur + delta, 0), items.count - 1)   // clamp at the ends
            guard next != cur else { return }                      // already at an end: true no-op
            target = next
        } else {
            target = delta > 0 ? 0 : items.count - 1               // nothing visible-selected yet
        }
        selectItem(items[target])
    }

    /// Highlight the row immediately, then ask the data controller to hydrate its detail. Grabbing
    /// first responder here is what enables arrow navigation after a click (see `keyDown`).
    private func selectItem(_ it: Item) {
        window?.makeFirstResponder(self)
        store.selectedItemId = it.id
        onSelectItem?(it)
    }

    /// Collapse or expand a grouped row's subtree (the store change triggers a rebuild).
    private func toggleCollapse(_ id: String) {
        if store.collapsedItems.contains(id) { store.collapsedItems.remove(id) }
        else { store.collapsedItems.insert(id) }
    }

    /// Collapse or expand an org's repo list in the panel (the store change triggers a rebuild).
    private func toggleOrgExpanded(_ id: String) {
        if store.expandedOrgs.contains(id) { store.expandedOrgs.remove(id) }
        else { store.expandedOrgs.insert(id) }
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
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: z(10)))
        var y: CGFloat = 0
        let head = FlippedView(frame: NSRect(x: 0, y: y, width: w, height: z(30)))
        let hl = label("ORGANIZATIONS", mono(9.5, .semibold), t.txt4)
        hl.frame = NSRect(x: z(14), y: z(9), width: z(160), height: z(14)); head.addSubview(hl)
        // The "manage" link opens the follow/unfollow + reorder sheet.
        let manage = ClickRow(bg: nil, radius: z(5))
        manage.hoverColor = t.hover
        manage.frame = NSRect(x: w - z(78), y: z(4), width: z(66), height: z(24))
        manage.onClick = { [weak self] in self?.onManageOrgs?() }
        let manageLabel = label("manage", sys(11, .semibold), t.accent, align: .right)
        manageLabel.frame = NSRect(x: 0, y: z(5), width: z(58), height: z(14)); manage.addSubview(manageLabel)
        head.addSubview(manage)
        doc.addSubview(head); y += z(30)

        let orgs = store.visibleOrgs
        if orgs.isEmpty {
            // First load: show a spinner; only fall back to the text hint once the fetch settles.
            if store.isLoadingOrgs {
                let spinner = makeSpinner(size: z(18))
                spinner.frame.origin = NSPoint(x: z(14), y: y + z(6)); doc.addSubview(spinner)
            } else {
                let hint = label(orgsEmptyHint(), sys(11.5), t.txt4, lines: 0)
                hint.frame = NSRect(x: z(14), y: y + z(4), width: w - z(28), height: z(34)); doc.addSubview(hint)
            }
            doc.frame.size.height = y + z(44)
            return (doc, y + z(44))
        }

        // A permanent aggregator pinned above the per-org rows: selecting it shows every visible
        // org's PRs/issues (the personal group included) as per-repo sections. It's not an entry in
        // `store.orgs` — so it can't be hidden/reordered in the manage sheet — and is backed by the
        // `Org.allOrgsID` sentinel, which the controller/store resolve to the union of visible repos.
        // A leaf row: no expand caret, since expanding would just duplicate the per-org rows below.
        let allSelected = store.selectedOrgId == Org.allOrgsID
        let allRow = ClickRow(bg: allSelected ? t.accentbg : nil, radius: z(6))
        allRow.hoverColor = t.hover
        allRow.frame = NSRect(x: 0, y: y, width: w, height: z(36))
        allRow.onClick = { [weak self] in self?.onSelectOrg?(Org.allOrgsID) }
        let allSq = BoxView(bg: allSelected ? t.accent : t.accentbg2, radius: z(6))
        allSq.frame = NSRect(x: z(14), y: z(7), width: z(22), height: z(22))
        let allGlyph = label("▦", sys(12, .bold), allSelected ? .white : t.accent, align: .center)
        allGlyph.frame = NSRect(x: 0, y: z(4), width: z(22), height: z(15))
        allSq.addSubview(allGlyph); allRow.addSubview(allSq)
        let allName = label("All organizations", sys(12.5, .semibold), t.txt)
        allName.frame = NSRect(x: z(46), y: z(9), width: w - z(46) - z(60), height: z(18)); allRow.addSubview(allName)
        let allCount = label("\(store.allOrgRepos.count)", mono(10), t.txt4, align: .right)
        allCount.frame = NSRect(x: w - z(56), y: z(9), width: z(24), height: z(18)); allRow.addSubview(allCount)
        doc.addSubview(allRow); y += z(36)

        for org in orgs {
            let expanded = store.expandedOrgs.contains(org.id)
            let selectedOrg = store.selectedOrgId == org.id
            let row = ClickRow(bg: selectedOrg ? t.accentbg : nil, radius: z(6))
            row.hoverColor = t.hover
            row.frame = NSRect(x: 0, y: y, width: w, height: z(36))
            // Clicking the row body selects the org (clearing any repo highlight), expands it, and
            // loads its aggregated items — the controller owns that selection + fetch. Clicking the
            // *already-selected* org instead toggles its repo list (collapse/expand) and stays
            // selected, so the caret isn't the only way to collapse it.
            row.onClick = { [weak self] in
                guard let self else { return }
                if self.store.selectedOrgId == org.id { self.toggleOrgExpanded(org.id) }
                else { self.onSelectOrg?(org.id) }
            }
            let sq = AvatarView(size: z(22), cornerRadius: z(6), url: org.avatarURL,
                                placeholderColor: org.color,
                                initials: String(org.name.prefix(2)).uppercased(),
                                initialsFont: sys(9, .bold), initialsColor: .white)
            sq.frame = NSRect(x: z(14), y: z(7), width: z(22), height: z(22))
            row.addSubview(sq)
            let nm = label(org.name, sys(12.5, .semibold), t.txt)
            nm.frame = NSRect(x: z(46), y: z(9), width: w - z(46) - z(60), height: z(18)); row.addSubview(nm)
            let rc = label("\(org.repos.count)", mono(10), t.txt4, align: .right)
            rc.frame = NSRect(x: w - z(56), y: z(9), width: z(24), height: z(18)); row.addSubview(rc)
            // The caret is a nested ClickRow that toggles collapse without selecting — a shortcut to
            // collapse an org you haven't selected (mirrors the grouped-row caret). Its accent tint is
            // the org row's selected glyph cue.
            let caretBox = ClickRow(bg: nil, radius: z(4))
            caretBox.hoverColor = t.hover
            caretBox.frame = NSRect(x: w - z(30), y: z(6), width: z(24), height: z(24))
            caretBox.onClick = { [weak self] in self?.toggleOrgExpanded(org.id) }
            let caret = label(expanded ? "▾" : "▸", sys(10), selectedOrg ? t.accent : t.txt4, align: .center)
            caret.frame = NSRect(x: z(6), y: z(3), width: z(12), height: z(18)); caretBox.addSubview(caret)
            row.addSubview(caretBox)
            doc.addSubview(row); y += z(36)

            if expanded {
                for rp in org.repos {
                    let selectedRepo = store.selectedRepoKey == "\(rp.owner)/\(rp.name)"
                    let rr = ClickRow(bg: selectedRepo ? t.accentbg : nil, radius: z(6))
                    rr.hoverColor = t.hover
                    rr.frame = NSRect(x: 0, y: y, width: w, height: z(28))
                    rr.onClick = { [weak self] in self?.onSelectRepo?(rp.owner, rp.name) }
                    let g = label("◇", sys(10), selectedRepo ? t.accent : t.txt4)
                    g.frame = NSRect(x: z(30), y: z(6), width: z(12), height: z(16)); rr.addSubview(g)
                    let rn = label(rp.name, sys(12), selectedRepo ? t.txt : t.txt2)
                    rn.frame = NSRect(x: z(46), y: z(5), width: w - z(46) - z(50), height: z(16)); rr.addSubview(rn)
                    let open = BoxView(bg: t.accentbg2, radius: z(9))
                    let ow = label("\(rp.open)", sys(9.5, .semibold), t.accent, align: .center)
                    let oww = max(z(20), ow.intrinsicContentSize.width + z(12))
                    open.frame = NSRect(x: w - oww - z(14), y: z(6), width: oww, height: z(16))
                    ow.frame = open.bounds; open.addSubview(ow); rr.addSubview(open)
                    doc.addSubview(rr); y += z(28)
                }
                y += z(4)
            }
        }
        doc.frame.size.height = y
        return (doc, y)
    }

    /// A cheap fingerprint of everything `orgRows` renders, so `ensureOrgsDoc` can tell a pure
    /// geometry change (the divider drag) — where nothing here changes — from a real content change
    /// (loading, selection, expand/collapse, a data refresh). Folds into one `Int` via `Hasher`;
    /// over-inclusion only costs a spurious rebuild, which never happens mid-drag.
    private func orgsSignature(width w: CGFloat, t: Theme) -> Int {
        var h = Hasher()
        h.combine(w); h.combine(uiScale); h.combine(t.key)
        h.combine(store.isLoadingOrgs); h.combine(store.dataError ?? "")
        // `authState` isn't Hashable and only its *case* drives the empty-state hint, so fold a
        // discriminator: signed-in shows orgs/hint, everything else shows the sign-in prompt.
        h.combine({ if case .signedIn = store.authState { return true } else { return false } }())
        h.combine(store.selectedOrgId); h.combine(store.selectedRepoKey ?? "")
        for id in store.expandedOrgs.sorted() { h.combine(id) }
        for org in store.visibleOrgs {
            h.combine(org.id); h.combine(org.name); h.combine(org.repos.count)
            for rp in org.repos { h.combine(rp.owner); h.combine(rp.name); h.combine(rp.open) }
        }
        return h.finalize()
    }

    /// Return the orgs document to install, building it via `orgRows` only when its signature changed;
    /// otherwise reuse the cached view (reparented into the fresh scroll view by the caller). Returns
    /// the natural content height so the caller can size/clamp the scroll region. See `cachedOrgsDoc`.
    private func ensureOrgsDoc(width w: CGFloat, t: Theme) -> CGFloat {
        let sig = orgsSignature(width: w, t: t)
        if sig != cachedOrgsSig || cachedOrgsDoc == nil {
            let (built, contentH) = orgRows(width: w, t: t)
            cachedOrgsDoc = built
            cachedOrgsSig = sig
            cachedOrgsContentH = contentH
        }
        cachedOrgsDoc?.frame.size.width = w
        return cachedOrgsContentH
    }

    private func itemCard(_ it: Item, width w: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedItemId == it.id
        let card = ClickRow(bg: t.card, radius: z(9))
        card.hoverColor = t.hover
        card.frame = NSRect(x: z(10), y: 0, width: w - z(20), height: z(52))
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (selected ? t.accent : t.cardbr).cgColor
        card.onClick = { [weak self] in self?.selectItem(it) }
        let cw = w - z(20)

        let dot = Dot(it.dotColor, z(8), radius: z(4))
        dot.frame.origin = NSPoint(x: z(10), y: z(10)); card.addSubview(dot)
        let num = label(it.num, mono(11), t.txt3)
        num.frame = NSRect(x: z(24), y: z(8), width: z(48), height: z(14)); card.addSubview(num)
        // Tooltip only when the ID is too long to fit (6+ digits), same truncation rule as the title.
        if fitW(num) > num.frame.width { num.toolTip = it.num }
        let title = label(it.title, sys(12.5, .medium), t.txt)
        title.frame = NSRect(x: z(74), y: z(8), width: cw - z(74) - z(70), height: z(14)); card.addSubview(title)
        // Tooltip only when the title is actually truncated — `fitW` is the width it needs to render
        // in full, so if that exceeds the label's frame the row is showing a tail ellipsis.
        if fitW(title) > title.frame.width { title.toolTip = it.title }
        let st = label(it.statusLabel, sys(10, .semibold), it.statusColor, align: .right)
        st.frame = NSRect(x: cw - z(76), y: z(8), width: z(70), height: z(14)); card.addSubview(st)

        let ml = label(it.metaLeft, mono(10), t.txt4)
        ml.frame = NSRect(x: z(25), y: z(28), width: cw / 2, height: z(14)); card.addSubview(ml)
        let mr = label(it.metaRight, mono(10), it.agentColor, align: .right)
        mr.frame = NSRect(x: cw - z(110), y: z(28), width: z(104), height: z(14)); card.addSubview(mr)
        return card
    }

    private func groupedRow(_ it: Item, indent: CGFloat, hasChildren: Bool,
                            width w: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedItemId == it.id
        let row = ClickRow(bg: selected ? t.accentbg : nil, radius: z(6))
        row.hoverColor = t.hover
        row.frame = NSRect(x: z(8), y: 0, width: w - z(16), height: z(27))
        row.onClick = { [weak self] in self?.selectItem(it) }
        let cw = w - z(16)
        // A disclosure caret sits in the indent gutter (left of the glyph) for rows with children;
        // it's a nested ClickRow so clicking it toggles collapse instead of selecting the row.
        if hasChildren {
            let collapsed = store.collapsedItems.contains(it.id)
            let caret = ClickRow(bg: nil, radius: z(4))
            caret.hoverColor = t.hover
            caret.frame = NSRect(x: indent, y: z(3), width: z(14), height: z(21))
            caret.onClick = { [weak self] in self?.toggleCollapse(it.id) }
            let cl = label(collapsed ? "▸" : "▾", sys(9), t.txt4, align: .center)
            cl.frame = NSRect(x: 0, y: z(5), width: z(14), height: z(12)); caret.addSubview(cl)
            row.addSubview(caret)
        }
        let g = label(it.glyph, sys(11), it.gcolor, align: .center)
        g.frame = NSRect(x: indent + z(14), y: z(6), width: z(14), height: z(14)); row.addSubview(g)
        let num = label(it.num, mono(11), t.txt3)
        num.frame = NSRect(x: indent + z(32), y: z(6), width: z(46), height: z(14)); row.addSubview(num)
        // Tooltip only when the ID is too long to fit (6+ digits), same truncation rule as the title.
        if fitW(num) > num.frame.width { num.toolTip = it.num }
        let title = label(it.title, sys(12), selected ? t.txt : t.txt2)
        title.frame = NSRect(x: indent + z(80), y: z(6), width: cw - indent - z(80) - z(22), height: z(14)); row.addSubview(title)
        // Tooltip only when the title is actually truncated (see `itemCard`).
        if fitW(title) > title.frame.width { title.toolTip = it.title }
        if it.blocked != nil {
            let b = label("⊘", sys(10), Status.red, align: .center)
            b.frame = NSRect(x: cw - z(20), y: z(6), width: z(14), height: z(14)); row.addSubview(b)
        }
        return row
    }

    /// Tree rows (id, depth, hasChildren — in list order) for `items`, nested by the active grouping:
    /// sub-issue parent ("By parent") or first blocker ("By blocked-by"). Relationships are same-repo
    /// numbers, keyed to the related item's composite id (`repo#number`) so they match the unique ids
    /// in `order`. The pure `GitHubItemTree` rule keeps roots/siblings in list order, treats an item
    /// whose related item isn't in view as a root, guards cycles, and honors collapse. Shared by the
    /// single-repo tree and each per-repo section of the aggregate org view.
    private func groupedTreeRows(_ items: [Item]) -> [GitHubItemTree.Row<String>] {
        let parentOf: [String: String] = items.reduce(into: [:]) { map, it in
            if let key = store.groupBy == .blocked ? it.blocked : it.parent {
                map[it.id] = "\(it.repo)#\(key)"
            }
        }
        return GitHubItemTree.rows(order: items.map(\.id), parentOf: parentOf,
                                   collapsed: store.collapsedItems)
    }

    /// A collapsible section header for the aggregate org view — one per repo, showing the repo's
    /// name and its item count. Clicking it toggles the section's collapse, keyed in `collapsedItems`
    /// by the repo's `owner/name` (which can't collide with an item's `repo#number`). In the "All
    /// organizations" scope the sections span multiple owners, so `showOwner` renders the full
    /// `owner/name` for disambiguation; a single org's sections share its owner and show just the name.
    private func repoSectionHeader(_ repoKey: String, count: Int, collapsed: Bool, showOwner: Bool,
                                   width w: CGFloat, t: Theme) -> ClickRow {
        let row = ClickRow(bg: nil, radius: z(6))
        row.hoverColor = t.hover
        row.frame = NSRect(x: z(8), y: 0, width: w - z(16), height: z(26))
        row.onClick = { [weak self] in self?.toggleCollapse(repoKey) }
        let shortName = showOwner ? repoKey : String(repoKey.split(separator: "/").last ?? Substring(repoKey))
        let caret = label(collapsed ? "▸" : "▾", sys(9), t.txt4, align: .center)
        caret.frame = NSRect(x: z(6), y: z(6), width: z(12), height: z(14)); row.addSubview(caret)
        let nm = label(shortName, sys(11.5, .semibold), t.txt2)
        nm.frame = NSRect(x: z(22), y: z(5), width: w - z(22) - z(50), height: z(16)); row.addSubview(nm)
        let cnt = label("\(count)", mono(10), t.txt4, align: .right)
        cnt.frame = NSRect(x: w - z(16) - z(40), y: z(5), width: z(32), height: z(16)); row.addSubview(cnt)
        return row
    }

    // MARK: layout

    private func rebuild() {
        // Capture the list's scroll position before tearing the panel down, so a plain repaint
        // (e.g. opening an item, which hydrates its detail) can restore it instead of jumping to top.
        let priorListOffset = listScroll?.contentView.bounds.origin
        let priorOrgsOffset = orgsScroll?.contentView.bounds.origin
        // Keep the persistent orgs splitter AND the list scroll view out of the teardown; everything
        // else is rebuilt from scratch. Reusing the list scroll view (rather than recreating it every
        // rebuild) is what lets an in-flight trackpad/momentum scroll survive a repaint — removing it
        // from the hierarchy mid-scroll would halt the gesture (the aggregate-org scroll-stops bug).
        subviews.forEach { if $0 !== orgsHandle && $0 !== self.listScroll { $0.removeFromSuperview() } }
        let t = store.theme
        layer?.backgroundColor = t.panel.cgColor
        let w = bounds.width
        guard w > 60 else { return }

        let lb = BoxView(bg: t.line)
        lb.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height); addSubview(lb)

        // 1. Orgs (scroll region; the user-draggable cap from `store.orgsListHeight`). The cap is
        // clamped so the orgs region keeps its floor and the chrome + list below it keep theirs — the
        // same `SplitLayout` clamp the divider drag uses (#91). The document is cached and reused when
        // its content is unchanged, so the divider drag doesn't rebuild it every frame.
        let orgsContentH = ensureOrgsDoc(width: w, t: t)
        let orgsCap = CGFloat(SplitLayout.clampExtent(
            Double(store.orgsListHeight), total: Double(bounds.height),
            minTerminal: SplitLayout.minOrgsListHeight, minDetail: Double(orgsBottomReserve)))
        // Once there are orgs, hold the region at its (clamped) cap and let it scroll internally, so
        // expanding/collapsing an org never resizes the issues list below it. Before any orgs load,
        // hug the small sign-in/loading hint rather than showing a tall empty box.
        let orgsH: CGFloat = store.visibleOrgs.isEmpty ? min(orgsContentH, orgsCap) : orgsCap
        let orgsScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: orgsH))
        orgsScroll.drawsBackground = false
        orgsScroll.hasVerticalScroller = true
        orgsScroll.autohidesScrollers = true
        orgsScroll.documentView = cachedOrgsDoc
        addSubview(orgsScroll)
        self.orgsScroll = orgsScroll
        if let token = orgsScrollObserver { NotificationCenter.default.removeObserver(token) }
        // Restore the user's place. On the first populated render, apply the *persisted* offset
        // (cross-launch restore); thereafter keep the live offset across repaints (selecting an
        // org/repo, a background refresh, expanding an org). Clamp to the new content in case the
        // list shrank — e.g. an org collapsed — so we never land in empty space.
        let targetY: CGFloat
        if !restoredOrgsScroll, !store.orgs.isEmpty {
            targetY = CGFloat(store.orgsScrollOffset)
            restoredOrgsScroll = true
        } else {
            targetY = priorOrgsOffset?.y ?? 0
        }
        let maxOrgsY = max(0, (cachedOrgsDoc?.frame.height ?? 0) - orgsScroll.contentView.bounds.height)
        orgsScroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, targetY), maxOrgsY)))
        orgsScroll.reflectScrolledClipView(orgsScroll.contentView)
        // Mirror the user's scroll into the store for persistence — only after the cross-launch
        // restore has run, so the empty/loading renders can't clobber the saved offset. A plain
        // store write (no repaint); the next `persist()` saves it.
        orgsScroll.contentView.postsBoundsChangedNotifications = true
        orgsScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: orgsScroll.contentView,
            queue: .main) { [weak self, weak orgsScroll] _ in
            guard let self, let orgsScroll, self.restoredOrgsScroll else { return }
            self.store.orgsScrollOffset = Double(orgsScroll.contentView.bounds.origin.y)
        }
        let ob = BoxView(bg: t.line)
        ob.frame = NSRect(x: 0, y: orgsH, width: w, height: 1); addSubview(ob)

        // 2. Repo header + tabs.
        var y = orgsH + z(12)
        let scopeTitle = store.scopeTitle
        let repoTitle = label(scopeTitle.isEmpty ? "No repository" : scopeTitle,
                              sys(13, .bold), scopeTitle.isEmpty ? t.txt4 : t.txt)
        var titleW = w - z(28)
        // The selected repo's star count sits to the right of its name — repo scope only (an org's
        // aggregate has no single total), public repos only (a private repo's count is withheld, #20).
        if let rp = store.selectedRepo, !rp.isPrivate {
            let starFont = sys(12, .semibold)
            let starText = "★ \(rp.stars)"
            let sw = fitW(starText, starFont)
            let star = label(starText, starFont, t.txt3, align: .right)
            star.frame = NSRect(x: w - z(14) - sw, y: y, width: sw, height: z(18)); addSubview(star)
            titleW -= sw + z(8)
        }
        repoTitle.frame = NSRect(x: z(14), y: y, width: titleW, height: z(18)); addSubview(repoTitle)
        y += z(30)

        let tabW = (w - z(28) - z(5)) / 2
        let prSel = store.tab == .prs
        let prTab = ClickRow(bg: prSel ? t.accentbg2 : t.card, radius: z(7))
        prTab.frame = NSRect(x: z(14), y: y, width: tabW, height: z(28))
        let prL = label("PRs · \(store.visiblePRs.count)", sys(11.5, .semibold), prSel ? t.accent : t.txt3, align: .center)
        prL.frame = NSRect(x: 0, y: z(6), width: tabW, height: z(16)); prTab.addSubview(prL)
        prTab.onClick = { [weak self] in self?.store.tab = .prs }
        addSubview(prTab)

        let isSel = store.tab == .issues
        let isTab = ClickRow(bg: isSel ? t.accentbg2 : t.card, radius: z(7))
        isTab.frame = NSRect(x: z(14) + tabW + z(5), y: y, width: tabW, height: z(28))
        let isL = label("Issues · \(store.visibleIssues.count)", sys(11.5, .semibold), isSel ? t.accent : t.txt3, align: .center)
        isL.frame = NSRect(x: 0, y: z(6), width: tabW, height: z(16)); isTab.addSubview(isL)
        isTab.onClick = { [weak self] in self?.store.tab = .issues }
        addSubview(isTab)
        y += z(38)

        // 2.5 Search row: a live free-text filter over the loaded list (title / number / labels),
        // modeled on the rail's search field. A keystroke rebuilds only the list document (see
        // `repopulateList`), so the field keeps focus while the rows below it narrow.
        addSubview(searchFieldRow(y: y, width: w, t: t))
        y += z(42)

        // 3. Controls row: the View (grouping) icon button, the inline sort control, and the status
        // filter share one row. View is shrunk to icon-only to free room for the sort control between.
        let gap: CGFloat = z(6)
        let viewW: CGFloat = z(50)
        let statusW: CGFloat = z(92)
        let sortX = z(12) + viewW + gap
        let statusX = w - z(12) - statusW
        let sortW = statusX - gap - sortX
        addSubview(dropdownButton(x: z(12), y: y, width: viewW, t: t, icon: "≣", text: "") { [weak self] in
            guard let self else { return }
            self.store.statusMenuOpen = false
            self.store.viewMenuOpen.toggle()
        })
        addSubview(sortControl(x: sortX, y: y, width: sortW, t: t))
        addSubview(dropdownButton(x: statusX, y: y, width: statusW, t: t, icon: "⚑",
                                  text: statusSummary()) { [weak self] in
            guard let self else { return }
            self.store.viewMenuOpen = false
            self.store.statusMenuOpen.toggle()
        })
        // Publish the regions where a click must NOT dismiss an open dropdown — the View/Status
        // toggle buttons and whichever menu is open — in window coords, for the window's `sendEvent`
        // to consult. The sort control opens no menu, so it's deliberately not listed: a tap there
        // both dismisses an open menu and applies the sort.
        if store.viewMenuOpen || store.statusMenuOpen {
            var rects = [NSRect(x: z(12), y: y, width: viewW, height: z(32)),
                         NSRect(x: statusX, y: y, width: statusW, height: z(32))]
            if store.viewMenuOpen {
                // The View menu stays full-width below the row — the grouping labels need the room.
                rects.append(NSRect(x: z(12), y: y + z(36), width: w - z(24),
                                    height: CGFloat(Store.GroupBy.allCases.count) * z(36) + z(10)))
            }
            if store.statusMenuOpen {
                rects.append(NSRect(x: statusX, y: y + z(36), width: statusW,
                                    height: CGFloat(statusOptions.count) * z(36) + z(10)))
            }
            store.menuDismissRects = rects.map { convert($0, to: nil) }
        } else {
            store.menuDismissRects = []
        }
        let listTop = y + z(42)

        // 4. List body. Reuse the persistent scroll view (kept out of the teardown above) rather than
        // recreating it, so a live scroll survives the repaint; only its frame is updated here.
        let listScroll = self.listScroll ?? NSScrollView()
        listScroll.frame = NSRect(x: 0, y: listTop, width: w, height: bounds.height - listTop - z(8))
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        // Reuse the cached document when the list content is unchanged (e.g. the divider drag), so a
        // few-hundred-item list isn't rebuilt every frame (#91). `selectedRect`/`docChanged` are the
        // reuse signal: on the reuse path the doc is untouched, so any selection change takes the build
        // path (which recomputes them); the focus block below only fires on a selection change.
        let (doc, selectedRect, docChanged) = installListDoc(into: listScroll, width: w, t: t)
        if listScroll.superview == nil { addSubview(listScroll) }
        self.listScroll = listScroll

        // Preserve the user's place across a plain repaint; reset to the top only when the list
        // itself changed (repo/tab/grouping/status-filter switch). Only needed when the document view
        // was actually swapped (which zeroes the scroll) — on the reuse path the position (and a live
        // momentum scroll) is kept naturally, so we must NOT call scroll(to:), which would halt it.
        let identity = [store.selectedOrgId, store.selectedRepoKey ?? "", store.tab.rawValue, store.groupBy.storageKey,
                        store.sortField.rawValue + (store.sortAscending ? "↑" : "↓"),
                        store.prStates.map(\.rawValue).sorted().joined(separator: ","),
                        store.issueStates.map(\.rawValue).sorted().joined(separator: ",")]
            .joined(separator: "|")
        if docChanged, identity == listIdentity, let off = priorListOffset {
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
            DispatchQueue.main.async { [weak doc] in doc?.scrollToVisible(rect.insetBy(dx: 0, dy: z(-28))) }
        }

        // Dropdown overlay.
        if store.viewMenuOpen {
            let menu = BoxView(bg: t.panel, radius: z(10), border: t.line2)
            let mh = CGFloat(Store.GroupBy.allCases.count) * z(36) + z(10)
            menu.frame = NSRect(x: z(12), y: y + z(36), width: w - z(24), height: mh)
            menu.layer?.shadowColor = NSColor.black.cgColor
            menu.layer?.shadowOpacity = 0.45
            menu.layer?.shadowRadius = z(16)
            menu.layer?.shadowOffset = CGSize(width: 0, height: z(-6))
            menu.layer?.masksToBounds = false
            var my: CGFloat = z(5)
            for g in Store.GroupBy.allCases {
                let on = store.groupBy == g
                let row = ClickRow(bg: on ? t.accentbg : nil, radius: z(7))
                row.hoverColor = t.hover
                row.frame = NSRect(x: z(5), y: my, width: w - z(24) - z(10), height: z(34))
                let chk = label(on ? "✓" : "", sys(11), t.accent); chk.frame = NSRect(x: z(10), y: z(9), width: z(14), height: z(16)); row.addSubview(chk)
                let gl = label(g.rawValue, sys(12.5), t.txt); gl.frame = NSRect(x: z(30), y: z(9), width: z(160), height: z(16)); row.addSubview(gl)
                row.onClick = { [weak self] in
                    self?.store.groupBy = g
                    self?.store.viewMenuOpen = false
                    self?.onChangeGroup?()   // lazily load blocked-by data on first entering that mode
                }
                menu.addSubview(row); my += z(36)
            }
            addSubview(menu)
        }

        // Status filter overlay — a multi-check menu of the active tab's states (Open/Closed, plus
        // Merged for PRs). Toggling keeps the menu open so several states can be flipped at once.
        if store.statusMenuOpen {
            let options = statusOptions
            let selected = store.tab == .prs ? store.prStates : store.issueStates
            let menu = BoxView(bg: t.panel, radius: z(10), border: t.line2)
            let mh = CGFloat(options.count) * z(36) + z(10)
            menu.frame = NSRect(x: statusX, y: y + z(36), width: statusW, height: mh)
            menu.layer?.shadowColor = NSColor.black.cgColor
            menu.layer?.shadowOpacity = 0.45
            menu.layer?.shadowRadius = z(16)
            menu.layer?.shadowOffset = CGSize(width: 0, height: z(-6))
            menu.layer?.masksToBounds = false
            var my: CGFloat = z(5)
            for state in options {
                let on = selected.contains(state)
                let row = ClickRow(bg: on ? t.accentbg : nil, radius: z(7))
                row.hoverColor = t.hover
                row.frame = NSRect(x: z(5), y: my, width: statusW - z(10), height: z(34))
                let chk = label(on ? "✓" : "", sys(11), t.accent); chk.frame = NSRect(x: z(10), y: z(9), width: z(14), height: z(16)); row.addSubview(chk)
                let gl = label(Self.stateName(state), sys(12.5), t.txt); gl.frame = NSRect(x: z(30), y: z(9), width: statusW - z(40), height: z(16)); row.addSubview(gl)
                row.onClick = { [weak self] in self?.toggleStatus(state) }
                menu.addSubview(row); my += z(36)
            }
            addSubview(menu)
        }

        // The orgs/issues splitter sits on the seam, added last so it's frontmost (#84). Only shown
        // when there are orgs to resize; otherwise (signed out / first load) there's nothing to drag.
        if store.visibleOrgs.isEmpty {
            orgsHandle.removeFromSuperview()
        } else {
            layoutOrgsHandle(seamY: orgsH, width: w, t: t)
        }
    }

    /// One entry in the list's visible, search/scope/group/collapse-aware order — the single source
    /// of truth shared by rendering (`buildListDoc`) and keyboard navigation (`moveSelection`), so the
    /// two can never disagree about what's on screen or in what order. Non-navigable chrome (the
    /// loading spinner and the "no match"/truncation notes) is intentionally *not* modeled here; it
    /// stays in `buildListDoc`. `.section`/`.sectionGap` carry the aggregate-org layout but have no
    /// `item`, so navigation skips them.
    private enum ListRow {
        case section(repoKey: String, count: Int, collapsed: Bool)   // aggregate-org repo header
        case card(Item)                                              // single-repo flat card
        case tree(Item, depth: Int, hasChildren: Bool)              // grouped / org-section row
        case sectionGap                                              // trailing gap below a section

        /// The selectable item this row represents, or nil for headers/spacers.
        var item: Item? {
            switch self {
            case .section, .sectionGap: return nil
            case let .card(it), let .tree(it, _, _): return it
            }
        }
    }

    /// The active tab's items narrowed by the live search query (an empty query yields the full list),
    /// via the pure `GitHubItemSearch` rule. The one place the filter is defined, so `visibleListRows`
    /// and the "no match" note agree.
    private func filteredListItems() -> [Item] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.listItems }
        return store.listItems.filter {
            GitHubItemSearch.matches(query: needle, title: $0.title, number: $0.number, labels: $0.labels)
        }
    }

    /// The list rows in display order — THE ordering authority. Applies the same search filter, org
    /// sectioning (`selectedOrgRepoKeys` + collapse), grouping (`groupedTreeRows`) and collapse the
    /// panel draws, so `buildListDoc` (which renders these) and `moveSelection` (which walks the
    /// navigable ones) share one definition. Returns `[]` on the loading-empty branch (the spinner is
    /// drawn separately) and for a genuinely empty list.
    private func visibleListRows() -> [ListRow] {
        if store.isLoadingItems && store.listItems.isEmpty { return [] }
        let items = filteredListItems()
        var rows: [ListRow] = []
        if store.isOrgScope {
            // Aggregate org view: one collapsible section per repo (in panel order). Within a section
            // the active grouping still applies — "By parent"/"By blocked-by" nest that repo's items
            // into a tree (relationships are same-repo), "Flat list" lists them flat. Items keep their
            // unique `repo#number` id, so selection works across repos.
            let byRepo = Dictionary(grouping: items, by: \.repo)
            for repoKey in store.selectedOrgRepoKeys {
                guard let repoItems = byRepo[repoKey], !repoItems.isEmpty else { continue }
                let collapsed = store.collapsedItems.contains(repoKey)
                rows.append(.section(repoKey: repoKey, count: repoItems.count, collapsed: collapsed))
                if collapsed { continue }
                if store.groupBy == .none {
                    for it in repoItems { rows.append(.tree(it, depth: 0, hasChildren: false)) }
                } else {
                    let byId = Dictionary(repoItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for r in groupedTreeRows(repoItems) {
                        guard let it = byId[r.id] else { continue }
                        rows.append(.tree(it, depth: r.depth, hasChildren: r.hasChildren))
                    }
                }
                rows.append(.sectionGap)
            }
        } else if store.groupBy == .none {
            for it in items { rows.append(.card(it)) }
        } else {
            // Grouped tree (single repo): nest by the active mode's relationship — sub-issue parent
            // ("By parent") or first blocker ("By blocked-by"), honoring collapse.
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for r in groupedTreeRows(items) {
                guard let it = byId[r.id] else { continue }
                rows.append(.tree(it, depth: r.depth, hasChildren: r.hasChildren))
            }
        }
        return rows
    }

    /// Build the (search-filtered) issue/PR list as a fresh document view, plus the open item's card
    /// rect (so the caller can scroll it into view). Renders `visibleListRows()` 1:1 into laid-out
    /// views — that helper owns the ordering, this owns the geometry. Factored out of `rebuild()` so a
    /// keystroke can rebuild just this document — keeping the sibling search field focused — via
    /// `repopulateList()`, not the whole panel.
    private func buildListDoc(width w: CGFloat, minHeight: CGFloat, t: Theme) -> (doc: FlippedView, selectedRect: NSRect?) {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: z(10)))
        var ly: CGFloat = z(6)
        var selectedRect: NSRect?   // the open item's card, captured so we can scroll it into view
        let all = store.listItems
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.isLoadingItems && all.isEmpty {
            // First load of this repo's items: a spinner where the cards will appear.
            let spinner = makeSpinner()
            spinner.frame.origin = NSPoint(x: (w - z(20)) / 2, y: z(16)); doc.addSubview(spinner)
            ly += z(52)
        } else {
            let rows = visibleListRows()
            for row in rows {
                switch row {
                case let .section(repoKey, count, collapsed):
                    let header = repoSectionHeader(repoKey, count: count, collapsed: collapsed,
                                                   showOwner: store.selectedOrgId == Org.allOrgsID,
                                                   width: w, t: t)
                    header.frame.origin.y = ly; doc.addSubview(header); ly += z(30)
                case let .card(it):
                    let c = itemCard(it, width: w, t: t)
                    c.frame.origin.y = ly; doc.addSubview(c)
                    if it.id == store.selectedItemId { selectedRect = c.frame }
                    ly += z(58)
                case let .tree(it, depth, hasChildren):
                    let gr = groupedRow(it, indent: CGFloat(depth) * z(18), hasChildren: hasChildren,
                                        width: w, t: t)
                    gr.frame.origin.y = ly; doc.addSubview(gr)
                    if it.id == store.selectedItemId { selectedRect = gr.frame }
                    ly += z(29)
                case .sectionGap:
                    ly += z(4)
                }
            }
            // A live query that hid every row — distinct from a genuinely empty list, so say so.
            // (org items always belong to the org's repos, so "no navigable row" ⇔ filter matched none.)
            if !needle.isEmpty, !rows.contains(where: { $0.item != nil }), !all.isEmpty {
                let note = label("No items match “\(needle)”.", sys(11.5), t.txt4, lines: 2)
                note.frame = NSRect(x: z(14), y: ly + z(4), width: w - z(28), height: z(30)); doc.addSubview(note)
                ly += z(38)
            }
        }
        // When the closed/merged history was bounded, say so rather than implying the list is complete.
        if store.listTruncated && !(store.isLoadingItems && all.isEmpty) {
            let note = label("Showing newest \(GitHubItemStates.historyCap) — older closed items not loaded.",
                             sys(10.5), t.txt4, lines: 2)
            note.frame = NSRect(x: z(14), y: ly + z(4), width: w - z(28), height: z(30)); doc.addSubview(note)
            ly += z(38)
        }
        doc.frame.size.height = max(ly, minHeight)
        return (doc, selectedRect)
    }

    /// A cheap fingerprint of everything `buildListDoc` renders, so `installListDoc` can tell a pure
    /// geometry change (the divider drag, which keeps width and content fixed) from a real content
    /// change. There is no revision counter in `Store` (`listItems` is derived from `prs`/`issues`) and
    /// `Item` isn't `Hashable`, so we fold the render-relevant fields explicitly. Over-inclusion only
    /// costs a spurious rebuild, which never happens mid-drag since none of these change then. Folding
    /// a few-hundred items is microseconds against the ~1000 text fields + `fitW()` measurements a
    /// rebuild would otherwise do every frame (#91).
    private func listSignature(width w: CGFloat, t: Theme) -> Int {
        var h = Hasher()
        h.combine(w); h.combine(uiScale); h.combine(t.key)
        h.combine(store.tab.rawValue); h.combine(store.groupBy.storageKey)
        h.combine(store.isOrgScope)
        for k in store.selectedOrgRepoKeys { h.combine(k) }
        for id in store.collapsedItems.sorted() { h.combine(id) }
        h.combine(store.selectedItemId)          // the selected card is styled differently
        h.combine(store.listTruncated); h.combine(store.isLoadingItems)
        h.combine(searchQuery)
        for it in store.listItems {
            h.combine(it.id); h.combine(it.number); h.combine(it.state.rawValue)
            h.combine(it.title); h.combine(it.num); h.combine(it.glyph); h.combine(it.statusLabel)
            h.combine(it.metaLeft); h.combine(it.metaRight); h.combine(it.isAgent)
            h.combine(it.epic); h.combine(it.blocked ?? ""); h.combine(it.parent ?? "")
            for l in it.labels { h.combine(l) }
            h.combine(it.repo)
        }
        return h.finalize()
    }

    /// Install the list document into `scroll`, building it via `buildListDoc` only when its content
    /// changed (per `listSignature`); otherwise reuse the cached document (reparenting an `NSView` into
    /// the fresh scroll view is cheap). Builds with `minHeight: 0` so the cached height is the natural
    /// content height, then stretches the installed doc to fill the (possibly resized) viewport —
    /// reproducing `buildListDoc`'s `max(ly, minHeight)` while the divider drag changes the viewport
    /// height every frame. Returns the installed doc and, on the *build* path only, the open item's
    /// card rect for scroll-into-view (nil on reuse — safe, see `rebuild`). See `cachedListDoc`.
    private func installListDoc(into scroll: NSScrollView, width w: CGFloat, t: Theme)
        -> (doc: FlippedView, selectedRect: NSRect?, docChanged: Bool) {
        let sig = listSignature(width: w, t: t)
        var selectedRect: NSRect?
        if sig != cachedListSig || cachedListDoc == nil {
            let built = buildListDoc(width: w, minHeight: 0, t: t)   // minHeight 0 → doc.height == content
            cachedListDoc = built.doc
            cachedListSig = sig
            cachedListContentH = built.doc.frame.height
            selectedRect = built.selectedRect
        }
        guard let doc = cachedListDoc else { return (FlippedView(frame: scroll.bounds), nil, true) }
        doc.frame.size.width = w
        doc.frame.size.height = max(cachedListContentH, scroll.frame.height)
        // Only reassign the document view when it actually changed — reassigning halts a live
        // trackpad/momentum scroll. On the reuse path (a detail-load or background repaint with
        // unchanged list content) the same doc stays installed, so the user's scroll is never
        // interrupted (the aggregate-org scroll-stops bug).
        let docChanged = scroll.documentView !== doc
        if docChanged { scroll.documentView = doc }
        return (doc, selectedRect, docChanged)
    }

    /// Rebuild only the list document in response to a search keystroke, leaving the (sibling) search
    /// field untouched so it keeps first-responder status and its insertion point. Resets to the top
    /// (a filtered list is a new list); the open-item scroll-into-view is intentionally not run here.
    /// Routed through `installListDoc` so the cache stays coherent — otherwise the first divider-drag
    /// frame after a keystroke would do one wasted full rebuild.
    private func repopulateList() {
        guard let scroll = listScroll else { return }
        _ = installListDoc(into: scroll, width: scroll.frame.width, t: store.theme)
    }

    /// The live search field row above the list: a borderless `NSTextField` in a card with a ⌕ glyph,
    /// styled like the rail's "Search connections" field. Filters the list as the user types (via the
    /// `NSTextFieldDelegate` extension below) and clears on Esc. The query is panel-local — see
    /// `searchQuery`.
    private func searchFieldRow(y: CGFloat, width w: CGFloat, t: Theme) -> NSView {
        let card = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
        card.frame = NSRect(x: z(12), y: y, width: w - z(24), height: z(32))
        let mag = label("⌕", sys(13), t.txt4)
        mag.frame = NSRect(x: z(10), y: z(7), width: z(16), height: z(18)); card.addSubview(mag)
        let field = NSTextField(string: searchQuery)
        field.font = sys(12.5)
        field.placeholderString = store.tab == .prs ? "Search pull requests…" : "Search issues…"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = t.txt
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
        field.frame = NSRect(x: z(30), y: z(7), width: w - z(24) - z(40), height: z(18))
        card.addSubview(field)
        searchField = field
        return card
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
        let dd = ClickRow(bg: t.card, radius: z(8))
        dd.frame = NSRect(x: x, y: y, width: width, height: z(32))
        dd.layer?.borderWidth = 1; dd.layer?.borderColor = t.cardbr.cgColor
        let car = label("▾", sys(10), t.txt4, align: .right); car.frame = NSRect(x: width - z(22), y: z(8), width: z(14), height: z(16)); dd.addSubview(car)
        if text.isEmpty {
            // Icon-only (the compact "View" control): icon + caret, no label, so it fits a narrow width.
            let ic = label(icon, sys(12), t.txt3, align: .center); ic.frame = NSRect(x: z(8), y: z(8), width: z(18), height: z(16)); dd.addSubview(ic)
        } else {
            let ic = label(icon, sys(12), t.txt3); ic.frame = NSRect(x: z(10), y: z(8), width: z(16), height: z(16)); dd.addSubview(ic)
            let l = label(text, sys(12, .semibold), t.txt)   // lines: 1 → already truncates with a tail
            l.frame = NSRect(x: z(30), y: z(8), width: width - z(30) - z(22), height: z(16)); dd.addSubview(l)
        }
        dd.onClick = onClick
        return dd
    }

    /// The inline sort control: three field cells (date / number / title) and an asc/desc chevron in
    /// one bordered box mirroring `dropdownButton`'s chrome. The active field is tinted with the
    /// accent. Unlike View/Status it opens no menu — tapping a field sets `sortField`, tapping the
    /// chevron toggles `sortAscending`, both directly (so it needs no entry in `menuDismissRects`).
    private func sortControl(x: CGFloat, y: CGFloat, width: CGFloat, t: Theme) -> ClickRow {
        let box = ClickRow(bg: t.card, radius: z(8))   // container chrome only; its own onClick stays nil
        box.frame = NSRect(x: x, y: y, width: width, height: z(32))
        box.layer?.borderWidth = 1; box.layer?.borderColor = t.cardbr.cgColor

        let fields: [(ItemSortField, String)] = [(.date, "◷"), (.number, "#"), (.title, "Az")]
        let chevW: CGFloat = z(22)
        let cellW = (width - chevW) / CGFloat(fields.count)
        for (i, f) in fields.enumerated() {
            let on = store.sortField == f.0
            let cell = ClickRow(bg: on ? t.accentbg : nil, radius: z(6))
            cell.hoverColor = t.hover
            cell.frame = NSRect(x: cellW * CGFloat(i) + z(2), y: z(4), width: cellW - z(3), height: z(24))
            let gl = label(f.1, sys(12, on ? .semibold : .regular), on ? t.accent : t.txt3, align: .center)
            gl.frame = NSRect(x: 0, y: z(4), width: cellW - z(3), height: z(16)); cell.addSubview(gl)
            cell.onClick = { [weak self] in self?.store.sortField = f.0 }
            box.addSubview(cell)
        }
        let chev = ClickRow(bg: nil, radius: z(6))
        chev.hoverColor = t.hover
        chev.frame = NSRect(x: width - chevW + 1, y: z(4), width: chevW - z(3), height: z(24))
        let cl = label(store.sortAscending ? "▲" : "▼", sys(9), t.txt3, align: .center)
        cl.frame = NSRect(x: 0, y: z(6), width: chevW - z(3), height: z(12)); chev.addSubview(cl)
        chev.onClick = { [weak self] in self?.store.sortAscending.toggle() }
        box.addSubview(chev)
        return box
    }
}

extension RepoPanelView: NSTextFieldDelegate {
    /// Live-filter the list as the user types. Updates only the panel-local query and the list
    /// document — never `store.notify()` — so the field keeps focus while the rows below it change.
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
