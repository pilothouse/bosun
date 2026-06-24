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

    private let rowH: CGFloat = 34

    // Live-drag session state. `listDoc` is the scroll document holding the rows; `followedRows`
    // maps an org id to its row view so the drag can reposition siblings without a full rebuild.
    private weak var listDoc: FlippedView?
    private var followedRows: [String: NSView] = [:]
    private var dragOrder: [String] = []
    private var draggingId: String?
    private var dragGrabDY: CGFloat = 0
    private var listTopInDoc: CGFloat = 0
    private var didFocus = false

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

        let cardW: CGFloat = 380
        let headerH: CGFloat = 64, footerH: CGFloat = 56
        // Each org gets a row; the "not shown" caption gets a half-row when both sections exist.
        let captionH: CGFloat = (!followed.isEmpty && !unfollowed.isEmpty) ? 24 : 0
        let contentH = CGFloat(orgs.count) * rowH + captionH + 12
        let listH = min(max(contentH, rowH), 360)
        let cardH = headerH + listH + footerH

        let card = ClickRow(bg: t.panel, radius: 12)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = t.line2.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 24
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.layer?.masksToBounds = false
        card.frame = NSRect(x: (bounds.width - cardW) / 2,
                            y: max(56, (bounds.height - cardH) / 2),
                            width: cardW, height: cardH)
        addSubview(card)
        buildCard(card, t: t, w: cardW, h: cardH, headerH: headerH, listH: listH,
                  followed: followed, unfollowed: unfollowed)

        if !didFocus, let window { didFocus = true; window.makeFirstResponder(self) }
    }

    private func buildCard(_ card: ClickRow, t: Theme, w: CGFloat, h: CGFloat,
                           headerH: CGFloat, listH: CGFloat,
                           followed: [Org], unfollowed: [Org]) {
        let pad: CGFloat = 20
        let innerW = w - pad * 2

        let title = label("Manage organizations", sys(15, .semibold), t.txt)
        title.frame = NSRect(x: pad, y: 18, width: innerW, height: 22); card.addSubview(title)
        let sub = label("Choose which orgs appear in the panel. Drag ☰ to reorder.",
                        sys(11, .regular), t.txt4, lines: 1)
        sub.frame = NSRect(x: pad, y: 41, width: innerW, height: 14); card.addSubview(sub)

        if store.orgs.isEmpty {
            let empty = label("No organizations on this account.", sys(12), t.txt3, align: .center)
            empty.frame = NSRect(x: pad, y: headerH + listH / 2 - 8, width: innerW, height: 16)
            card.addSubview(empty)
        } else {
            buildList(in: card, t: t, x: 0, y: headerH, w: w, h: listH,
                      followed: followed, unfollowed: unfollowed)
        }

        // Footer: Reset (back to show-all) on the left, Done on the right.
        let btnW: CGFloat = 84, btnH: CGFloat = 30, btnY = h - 44
        let reset = textButton("Reset", t: t, accent: false,
                               frame: NSRect(x: pad, y: btnY, width: btnW, height: btnH)) { [weak self] in
            self?.store.followedOrgs = nil
        }
        let done = textButton("Done", t: t, accent: true,
                              frame: NSRect(x: pad + innerW - btnW, y: btnY, width: btnW, height: btnH)) { [weak self] in
            self?.onClose?()
        }
        card.addSubview(reset); card.addSubview(done)
    }

    private func buildList(in card: ClickRow, t: Theme, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                           followed: [Org], unfollowed: [Org]) {
        let scroll = NSScrollView(frame: NSRect(x: x, y: y, width: w, height: h))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: 10))
        listDoc = doc

        followedRows = [:]
        dragOrder = followed.map(\.id)
        let canReorder = followed.count >= 2

        var dy: CGFloat = 6
        listTopInDoc = dy
        for org in followed {
            let row = orgRow(org, t: t, w: w, followed: true, draggable: canReorder)
            row.frame.origin = NSPoint(x: 0, y: dy); doc.addSubview(row)
            followedRows[org.id] = row
            dy += rowH
        }

        if !followed.isEmpty && !unfollowed.isEmpty {
            let cap = label("NOT SHOWN", mono(9.5, .semibold), t.txt4)
            cap.frame = NSRect(x: 20, y: dy + 6, width: 160, height: 12); doc.addSubview(cap)
            dy += 24
        }

        for org in unfollowed {
            let row = orgRow(org, t: t, w: w, followed: false, draggable: false)
            row.frame.origin = NSPoint(x: 0, y: dy); doc.addSubview(row)
            dy += rowH
        }

        doc.frame.size = NSSize(width: w, height: max(dy + 6, h))
        scroll.documentView = doc
        card.addSubview(scroll)
    }

    /// One org row: drag handle (followed + reorderable only), follow checkbox, color square, name.
    private func orgRow(_ org: Org, t: Theme, w: CGFloat, followed: Bool, draggable: Bool) -> ClickRow {
        let row = ClickRow(bg: nil, radius: 7)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 8, y: 0, width: w - 16, height: rowH - 4)
        row.onClick = { [weak self] in self?.toggle(org.id) }

        if draggable {
            let handle = OrgDragGrip(frame: NSRect(x: 6, y: 0, width: 24, height: rowH - 4))
            let hl = label("☰", sys(13), t.txt4, align: .center)
            hl.frame = NSRect(x: 0, y: (rowH - 4 - 16) / 2, width: 24, height: 16); handle.addSubview(hl)
            handle.onDown = { [weak self] e in self?.beginDrag(org.id, event: e) }
            handle.onDrag = { [weak self] e in self?.updateDrag(event: e) }
            handle.onUp = { [weak self] _ in self?.endDrag() }
            row.addSubview(handle)
        }

        let check = label(followed ? "☑" : "☐", sys(13), followed ? t.accent : t.txt4)
        check.frame = NSRect(x: 34, y: (rowH - 4 - 16) / 2, width: 16, height: 16); row.addSubview(check)

        let sq = BoxView(bg: org.color, radius: 5)
        sq.frame = NSRect(x: 58, y: (rowH - 4 - 18) / 2, width: 18, height: 18)
        let initials = label(String(org.name.prefix(2)).uppercased(), sys(8, .bold), .white, align: .center)
        initials.frame = sq.bounds.insetBy(dx: 0, dy: 4); sq.addSubview(initials)
        row.addSubview(sq)

        let nm = label(org.name, sys(12.5, followed ? .semibold : .regular), followed ? t.txt : t.txt3)
        nm.frame = NSRect(x: 84, y: (rowH - 4 - 16) / 2, width: w - 16 - 84 - 12, height: 16)
        row.addSubview(nm)
        return row
    }

    private func textButton(_ title: String, t: Theme, accent: Bool, frame: NSRect, action: @escaping () -> Void) -> ClickRow {
        let r = ClickRow(bg: accent ? t.accent : t.card, radius: 7)
        r.hoverColor = accent ? nil : t.hover
        if !accent { r.layer?.borderWidth = 1; r.layer?.borderColor = t.line2.cgColor }
        r.frame = frame
        r.onClick = action
        let l = label(title, sys(12, .semibold), accent ? t.onacc : t.txt2, align: .center)
        l.frame = NSRect(x: 0, y: (frame.height - 16) / 2, width: frame.width, height: 16)
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
        row.layer?.shadowRadius = 8
        row.layer?.shadowOffset = CGSize(width: 0, height: 2)
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
