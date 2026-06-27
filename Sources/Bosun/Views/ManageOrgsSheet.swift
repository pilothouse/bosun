import AppKit
import Domain

/// Modal overlay to manage which organizations appear in the right panel: follow/unfollow with
/// the checkbox, and reorder the followed ones by dragging the ☰ handle. Follows the
/// `NewConnectionSheet` pattern (full-bounds dim backdrop, centered themed card, backdrop/Esc
/// dismiss). The source of truth is `store.followedOrgs` (persisted); every edit writes it and the
/// panel behind the sheet repaints. The ordering rule itself is `Domain.OrgFollowing.reorder`.
final class ManageOrgsSheet: FlippedView {
    private let store: Store
    var onClose: (() -> Void)?
    /// Open the GitHub page where the user grants/revokes this OAuth App's org access (#81).
    var onChangeAccess: (() -> Void)?
    /// Re-fetch the accessible org set with the current token and re-project the panel — no restart.
    var onSyncOrgs: (() -> Void)?
    /// Re-run the device flow to obtain a token that sees freshly-granted access (the escape hatch
    /// for when a plain Sync can't surface a newly-authorized org).
    var onReconnect: (() -> Void)?

    private let rowH: CGFloat = z(34)

    // Live-drag session state. `listDoc` is the scroll document holding the rows; `followedRows`
    // maps an org id to its row view so the drag can reposition siblings without a full rebuild.
    private weak var listDoc: FlippedView?
    private var followedRows: [String: NSView] = [:]
    private var dragOrder: [String] = []
    private var draggingId: String?
    private var dragGrabDY: CGFloat = 0
    private var listTopInDoc: CGFloat = 0
    private var didFocus = false
    /// Whether the "Order:" repo-ordering dropdown is open. Local to the sheet (a modal), so the
    /// panel's window-level dismissal machinery isn't involved — a click elsewhere on the card closes it.
    private var orderMenuOpen = false
    /// True while a "Sync organizations" is showing its 2-second loading state — gates re-clicks and
    /// swaps the link for a spinner. Survives the sheet's per-`notify()` rebuilds (it's stored state).
    private var isSyncing = false

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks on the dim backdrop dismiss; Esc dismisses. The card (a ClickRow) swallows clicks.
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    // Take key focus (there's no text field to hold it, unlike NewConnectionSheet) so Esc reaches
    // `cancelOperation`. BosunView restores terminal focus when the sheet closes.
    override var acceptsFirstResponder: Bool { true }

    // MARK: Followed-set helpers

    /// The followed ids, materializing the "show all" default so an edit has a concrete list to
    /// mutate (an uncustomized `nil` means every org is followed).
    private func currentFollowed() -> [String] {
        store.followedOrgs ?? store.orgs.map(\.id)
    }

    private func setFollowed(_ ids: [String]) { store.followedOrgs = ids }

    private func toggle(_ id: String) {
        var ids = currentFollowed()
        if let idx = ids.firstIndex(of: id) { ids.remove(at: idx) } else { ids.append(id) }
        setFollowed(ids)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Never tear the rows down mid-drag — the gesture repositions the live views directly.
        if draggingId != nil { return }
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = NSColor.blackA(0.45).cgColor

        let orgs = store.orgs
        let followed = currentFollowed().compactMap { id in orgs.first { $0.id == id } }
        let followedSet = Set(followed.map(\.id))
        let unfollowed = orgs.filter { !followedSet.contains($0.id) }

        let cardW: CGFloat = z(380)
        // The header holds the title, subtitle, and the repo-ordering dropdown row. The footer holds
        // two rows: the org-access actions (Sync / Change access / Reconnect) and the Reset / Done bar.
        let headerH: CGFloat = z(104), footerH: CGFloat = z(96)
        // Each org gets a row; the "not shown" caption gets a half-row when both sections exist.
        let captionH: CGFloat = (!followed.isEmpty && !unfollowed.isEmpty) ? z(24) : 0
        let contentH = CGFloat(orgs.count) * rowH + captionH + z(12)
        let listH = min(max(contentH, rowH), z(360))
        let cardH = headerH + listH + footerH

        let card = ClickRow(bg: t.panel, radius: z(12))
        card.layer?.borderWidth = 1
        card.layer?.borderColor = t.line2.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = z(24)
        card.layer?.shadowOffset = CGSize(width: 0, height: z(-8))
        card.layer?.masksToBounds = false
        card.frame = NSRect(x: (bounds.width - cardW) / 2,
                            y: max(z(56), (bounds.height - cardH) / 2),
                            width: cardW, height: cardH)
        addSubview(card)
        buildCard(card, t: t, w: cardW, h: cardH, headerH: headerH, listH: listH,
                  followed: followed, unfollowed: unfollowed)

        if !didFocus, let window { didFocus = true; window.makeFirstResponder(self) }
    }

    private func buildCard(_ card: ClickRow, t: Theme, w: CGFloat, h: CGFloat,
                           headerH: CGFloat, listH: CGFloat,
                           followed: [Org], unfollowed: [Org]) {
        let pad: CGFloat = z(20)
        let innerW = w - pad * 2

        let title = label("Manage organizations", sys(15, .semibold), t.txt)
        title.frame = NSRect(x: pad, y: z(18), width: innerW, height: z(22)); card.addSubview(title)
        let sub = label("Choose which orgs appear in the panel. Drag ☰ to reorder.",
                        sys(11, .regular), t.txt4, lines: 1)
        sub.frame = NSRect(x: pad, y: z(41), width: innerW, height: z(14)); card.addSubview(sub)

        // Repo-ordering dropdown: same shape as the panel's View-options button.
        let orderCap = label("Order:", sys(11.5), t.txt3)
        orderCap.frame = NSRect(x: pad, y: z(70), width: z(44), height: z(16)); card.addSubview(orderCap)
        let ddX = pad + z(50), ddW: CGFloat = z(150)
        let dd = ClickRow(bg: t.card, radius: z(8))
        dd.hoverColor = t.hover
        dd.frame = NSRect(x: ddX, y: z(65), width: ddW, height: z(30))
        dd.layer?.borderWidth = 1; dd.layer?.borderColor = t.cardbr.cgColor
        let ddl = label(Self.orderLabel(store.repoOrdering), sys(12, .semibold), t.txt)
        ddl.frame = NSRect(x: z(12), y: z(7), width: ddW - z(12) - z(22), height: z(16)); dd.addSubview(ddl)
        let ddc = label("▾", sys(10), t.txt4, align: .right)
        ddc.frame = NSRect(x: ddW - z(22), y: z(7), width: z(14), height: z(16)); dd.addSubview(ddc)
        dd.onClick = { [weak self] in self?.orderMenuOpen.toggle(); self?.needsLayout = true }
        card.addSubview(dd)

        // A click anywhere else on the card dismisses an open order menu (menu rows/button intercept
        // their own clicks; the card otherwise just swallows clicks so they don't reach the backdrop).
        card.onClick = { [weak self] in
            guard let self, self.orderMenuOpen else { return }
            self.orderMenuOpen = false; self.needsLayout = true
        }

        if store.orgs.isEmpty {
            let empty = label("No organizations on this account.", sys(12), t.txt3, align: .center)
            empty.frame = NSRect(x: pad, y: headerH + listH / 2 - z(8), width: innerW, height: z(16))
            card.addSubview(empty)
        } else {
            buildList(in: card, t: t, x: 0, y: headerH, w: w, h: listH,
                      followed: followed, unfollowed: unfollowed)
        }

        // Footer row 1 — org-access actions: re-sync the set with the current token, or jump to GitHub
        // to change which orgs the app may see. These don't touch the followed set; they refresh which
        // orgs *exist* to follow (#81). Each link is sized to its text so the hover highlight hugs it.
        let actionsY = h - z(78), actionsH: CGFloat = z(26)
        if isSyncing {
            // While syncing, the link is replaced by a non-clickable spinner so it can't be spammed.
            let cy = actionsY + (actionsH - z(14)) / 2
            let spin = makeSpinner(size: z(14))
            spin.frame = NSRect(x: pad + z(7), y: cy, width: z(14), height: z(14)); card.addSubview(spin)
            let lbl = label("Syncing…", sys(11.5, .semibold), t.txt4)
            lbl.frame = NSRect(x: pad + z(27), y: cy, width: fitW("Syncing…", sys(11.5, .semibold)), height: z(14))
            card.addSubview(lbl)
        } else {
            let sync = linkRow("↻ Sync organizations", t: t, color: t.accent, y: actionsY, height: actionsH) { [weak self] in
                self?.startSync()
            }
            sync.frame.origin.x = pad
            card.addSubview(sync)
        }
        let access = linkRow("Change access on GitHub ↗", t: t, color: t.accent, y: actionsY, height: actionsH) { [weak self] in
            self?.onChangeAccess?()
        }
        access.frame.origin.x = pad + innerW - access.frame.width   // right-anchored, hugging its text
        card.addSubview(access)

        // Footer row 2 — Reset (back to show-all) on the left, Done on the right, with the low-emphasis
        // Reconnect escape hatch centered between them (for when a plain Sync can't surface new access).
        let btnW: CGFloat = z(84), btnH: CGFloat = z(30), btnY = h - z(44)
        let reset = textButton("Reset", t: t, accent: false,
                               frame: NSRect(x: pad, y: btnY, width: btnW, height: btnH)) { [weak self] in
            self?.store.followedOrgs = nil
        }
        let done = textButton("Done", t: t, accent: true,
                              frame: NSRect(x: pad + innerW - btnW, y: btnY, width: btnW, height: btnH)) { [weak self] in
            self?.onClose?()
        }
        let reconnect = linkRow("Reconnect GitHub", t: t, color: t.txt4, y: btnY + z(2), height: actionsH) { [weak self] in
            self?.onReconnect?()
        }
        reconnect.frame.origin.x = pad + (innerW - reconnect.frame.width) / 2
        card.addSubview(reset); card.addSubview(done); card.addSubview(reconnect)

        // Order menu overlay — added last so it floats above the list. Mirrors the panel's
        // View-options dropdown (RepoPanelView): a ✓ on the active mode, label, row per case.
        if orderMenuOpen {
            let modes = RepoOrderingMode.allCases
            let menu = BoxView(bg: t.panel, radius: z(10), border: t.line2)
            menu.frame = NSRect(x: ddX, y: z(65) + z(34), width: ddW, height: CGFloat(modes.count) * z(36) + z(10))
            menu.layer?.shadowColor = NSColor.black.cgColor
            menu.layer?.shadowOpacity = 0.45
            menu.layer?.shadowRadius = z(16)
            menu.layer?.shadowOffset = CGSize(width: 0, height: z(-6))
            menu.layer?.masksToBounds = false
            var my: CGFloat = z(5)
            for mode in modes {
                let on = store.repoOrdering == mode
                let row = ClickRow(bg: on ? t.accentbg : nil, radius: z(7))
                row.hoverColor = t.hover
                row.frame = NSRect(x: z(5), y: my, width: ddW - z(10), height: z(34))
                let chk = label(on ? "✓" : "", sys(11), t.accent)
                chk.frame = NSRect(x: z(10), y: z(9), width: z(14), height: z(16)); row.addSubview(chk)
                let ml = label(Self.orderLabel(mode), sys(12.5), t.txt)
                ml.frame = NSRect(x: z(30), y: z(9), width: ddW - z(40), height: z(16)); row.addSubview(ml)
                row.onClick = { [weak self] in
                    self?.store.repoOrdering = mode
                    self?.orderMenuOpen = false
                    self?.needsLayout = true
                }
                menu.addSubview(row); my += z(36)
            }
            card.addSubview(menu)
        }
    }

    /// The dropdown/menu label for an ordering mode. The Domain enum's raw values are storage keys,
    /// so the UI text lives here.
    private static func orderLabel(_ mode: RepoOrderingMode) -> String {
        switch mode {
        case .byName: "Name"
        case .byOpenCount: "Activity"
        }
    }

    private func buildList(in card: ClickRow, t: Theme, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                           followed: [Org], unfollowed: [Org]) {
        let scroll = NSScrollView(frame: NSRect(x: x, y: y, width: w, height: h))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: z(10)))
        listDoc = doc

        followedRows = [:]
        dragOrder = followed.map(\.id)
        let canReorder = followed.count >= 2

        var dy: CGFloat = z(6)
        listTopInDoc = dy
        for org in followed {
            let row = orgRow(org, t: t, w: w, followed: true, draggable: canReorder)
            row.frame.origin = NSPoint(x: 0, y: dy); doc.addSubview(row)
            followedRows[org.id] = row
            dy += rowH
        }

        if !followed.isEmpty && !unfollowed.isEmpty {
            let cap = label("NOT SHOWN", mono(9.5, .semibold), t.txt4)
            cap.frame = NSRect(x: z(20), y: dy + z(6), width: z(160), height: z(12)); doc.addSubview(cap)
            dy += z(24)
        }

        for org in unfollowed {
            let row = orgRow(org, t: t, w: w, followed: false, draggable: false)
            row.frame.origin = NSPoint(x: 0, y: dy); doc.addSubview(row)
            dy += rowH
        }

        doc.frame.size = NSSize(width: w, height: max(dy + z(6), h))
        scroll.documentView = doc
        card.addSubview(scroll)
    }

    /// One org row: drag handle (followed + reorderable only), follow checkbox, color square, name.
    private func orgRow(_ org: Org, t: Theme, w: CGFloat, followed: Bool, draggable: Bool) -> ClickRow {
        let row = ClickRow(bg: nil, radius: z(7))
        row.hoverColor = t.hover
        row.frame = NSRect(x: z(8), y: 0, width: w - z(16), height: rowH - z(4))
        row.onClick = { [weak self] in self?.toggle(org.id) }

        if draggable {
            let handle = OrgDragGrip(frame: NSRect(x: z(6), y: 0, width: z(24), height: rowH - z(4)))
            let hl = label("☰", sys(13), t.txt4, align: .center)
            hl.frame = NSRect(x: 0, y: (rowH - z(4) - z(16)) / 2, width: z(24), height: z(16)); handle.addSubview(hl)
            handle.onDown = { [weak self] e in self?.beginDrag(org.id, event: e) }
            handle.onDrag = { [weak self] e in self?.updateDrag(event: e) }
            handle.onUp = { [weak self] _ in self?.endDrag() }
            row.addSubview(handle)
        }

        let check = label(followed ? "☑" : "☐", sys(13), followed ? t.accent : t.txt4)
        check.frame = NSRect(x: z(34), y: (rowH - z(4) - z(16)) / 2, width: z(16), height: z(16)); row.addSubview(check)

        let sq = BoxView(bg: org.color, radius: z(5))
        sq.frame = NSRect(x: z(58), y: (rowH - z(4) - z(18)) / 2, width: z(18), height: z(18))
        let initials = label(String(org.name.prefix(2)).uppercased(), sys(8, .bold), .white, align: .center)
        initials.frame = sq.bounds.insetBy(dx: 0, dy: z(4)); sq.addSubview(initials)
        row.addSubview(sq)

        let nm = label(org.name, sys(12.5, followed ? .semibold : .regular), followed ? t.txt : t.txt3)
        nm.frame = NSRect(x: z(84), y: (rowH - z(4) - z(16)) / 2, width: w - z(16) - z(84) - z(12), height: z(16))
        row.addSubview(nm)
        return row
    }

    /// A borderless, hoverable text link — the footer's org-access actions. Same shape as the sidebar's
    /// "manage" link (`RepoPanelView`): a `ClickRow` wrapping a single label, no background or border.
    /// Sized to hug its text (via `fitW`) so the hover highlight doesn't extend past the label; the
    /// caller positions it by setting `frame.origin.x`.
    private func linkRow(_ title: String, t: Theme, color: NSColor, y: CGFloat, height: CGFloat,
                         action: @escaping () -> Void) -> ClickRow {
        let font = sys(11.5, .semibold)
        let tw = fitW(title, font), padX = z(7)
        let r = ClickRow(bg: nil, radius: z(5))
        r.hoverColor = t.hover
        r.frame = NSRect(x: 0, y: y, width: tw + padX * 2, height: height)
        r.onClick = action
        let l = label(title, font, color)
        l.frame = NSRect(x: padX, y: (height - z(14)) / 2, width: tw, height: z(14))
        r.addSubview(l)
        return r
    }

    /// Run a re-sync and show a 2-second loading state in its place, so the action can't be spammed and
    /// the user gets clear feedback even when the fetch returns instantly. Re-clicks are ignored while
    /// the spinner is up. Matches the transient-state idiom used elsewhere (`DetailView`/`DeviceFlowSheet`).
    private func startSync() {
        guard !isSyncing else { return }
        isSyncing = true
        needsLayout = true
        onSyncOrgs?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isSyncing = false
            self?.needsLayout = true
        }
    }

    private func textButton(_ title: String, t: Theme, accent: Bool, frame: NSRect, action: @escaping () -> Void) -> ClickRow {
        let r = ClickRow(bg: accent ? t.accent : t.card, radius: z(7))
        r.hoverColor = accent ? nil : t.hover
        if !accent { r.layer?.borderWidth = 1; r.layer?.borderColor = t.line2.cgColor }
        r.frame = frame
        r.onClick = action
        let l = label(title, sys(12, .semibold), accent ? t.onacc : t.txt2, align: .center)
        l.frame = NSRect(x: 0, y: (frame.height - z(16)) / 2, width: frame.width, height: z(16))
        r.addSubview(l)
        return r
    }

    // MARK: Drag-to-reorder (followed section)

    private func beginDrag(_ id: String, event: NSEvent) {
        guard let doc = listDoc, let row = followedRows[id], dragOrder.contains(id) else { return }
        draggingId = id
        let p = doc.convert(event.locationInWindow, from: nil)
        dragGrabDY = p.y - row.frame.origin.y
        doc.addSubview(row)                 // raise above siblings
        row.layer?.shadowColor = NSColor.black.cgColor
        row.layer?.shadowOpacity = 0.35
        row.layer?.shadowRadius = z(8)
        row.layer?.shadowOffset = CGSize(width: 0, height: z(2))
        row.layer?.masksToBounds = false
        (row as? ClickRow)?.setBase(store.theme.card)
    }

    private func updateDrag(event: NSEvent) {
        guard let id = draggingId, let doc = listDoc, let row = followedRows[id],
              let from = dragOrder.firstIndex(of: id) else { return }
        let n = dragOrder.count
        let p = doc.convert(event.locationInWindow, from: nil)
        let minY = listTopInDoc, maxY = listTopInDoc + CGFloat(n - 1) * rowH
        let newTop = max(minY, min(maxY, p.y - dragGrabDY))
        row.frame.origin.y = newTop

        var target = Int(((newTop + rowH / 2) - listTopInDoc) / rowH)
        target = max(0, min(n - 1, target))
        if target != from { dragOrder = OrgFollowing.reorder(dragOrder, from: from, to: target) }

        // Reflow the non-dragged rows into their slots so the gap follows the cursor.
        for (i, oid) in dragOrder.enumerated() where oid != id {
            followedRows[oid]?.frame.origin.y = listTopInDoc + CGFloat(i) * rowH
        }
    }

    private func endDrag() {
        guard draggingId != nil else { return }
        draggingId = nil
        setFollowed(dragOrder)   // persists + triggers the settling rebuild
    }
}

/// A bare view that forwards its mouse-tracking events; used as the ☰ reorder grip so a drag
/// there moves the row while a click elsewhere on the row toggles follow.
private final class OrgDragGrip: NSView {
    var onDown: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onUp: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onDown?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onUp?(event) }
}
