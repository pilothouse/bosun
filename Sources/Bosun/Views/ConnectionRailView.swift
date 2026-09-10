import AppKit
import Domain

final class ConnectionRailView: FlippedView {
    let store: Store
    var onAdd: (() -> Void)?
    var onEdit: ((String) -> Void)?
    /// Copy a connection with all its fields into a new one, named "<original> (copy)" (#101).
    var onDuplicate: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onToggleFavorite: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    /// A drag reordered a section: (the section's ids in their pre-move display order, the moved
    /// row's old index, its new index). The App layer applies `ConnectionOrdering` and persists.
    var onReorder: (([UUID], Int, Int) -> Void)?
    /// The footer "New folder" affordance was tapped. The App layer creates a folder and calls
    /// `beginRenamingFolder` so the user names it inline (Finder-style).
    var onCreateFolder: (() -> Void)?
    /// A folder header was renamed inline: (folder id, the new trimmed name). Empty input is ignored
    /// by the caller — the previous name stays.
    var onRenameFolder: ((String, String) -> Void)?
    /// A folder's Delete affordance was chosen: (folder id). The App layer shows the cascade-delete
    /// confirm dialog and, on confirm, removes the folder and its connections.
    var onDeleteFolder: ((String) -> Void)?
    /// A connection moved folders, by drag onto another section's band or the row's "Move to folder…"
    /// menu: (connection id, target folder id or nil for Ungrouped). The App layer persists it.
    var onMoveConnection: ((String, String?) -> Void)?

    // Double-click is tracked here, not via the row's clickCount: selecting a connection rebuilds
    // the rail and replaces the row between the two clicks, so AppKit's native double-click
    // detection fired only intermittently ("sometimes doesn't open").
    private var lastClickId: String?
    private var lastClickAt: TimeInterval = 0
    // Folder-header click timing (single click toggles collapse, a quick second renames), tracked
    // here for the same reason as `lastClickId`. The id currently in inline-rename, and its live
    // editor, mirror `TerminalContainerView`'s tab-rename state.
    private var lastFolderClickId: String?
    private var lastFolderClickAt: TimeInterval = 0
    private var editingFolderId: String?
    private weak var folderEditField: NSTextField?

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
    // Drag state is keyed by a per-row *token* ("<section>/<connId>"), not the connection id: a
    // favorited connection appears in both Favorites and its folder, so the same id renders twice —
    // the token disambiguates which rendered row the grip is dragging.
    private weak var listDoc: FlippedView?
    private var rowsById: [String: ClickRow] = [:]          // token → row
    private var sectionTokensById: [String: [String]] = [:] // token → its section's tokens, in display order
    private var sectionConnIdsById: [String: [String]] = [:]// token → its section's connection ids, in display order
    private var sectionTopById: [String: CGFloat] = [:]     // token → its section's first-row top-Y in doc
    private var rowConnId: [String: String] = [:]           // token → the connection id it shows
    private var rowFolderById: [String: String?] = [:]      // token → the folder it sits in (move origin; nil = ungrouped/favorites)
    private var dragReorderOnlyById: [String: Bool] = [:]   // token → its section is reorder-only (Favorites / no-folders flat list)
    private var draggingId: String?                         // the dragged row's token
    private var draggingOriginFolderId: String?             // the dragged row's folder when the drag began
    private var dragOrder: [String] = []                    // live order (tokens) of the dragged row's section
    private var dragGrabDY: CGFloat = 0
    private var dragSectionTop: CGFloat = 0
    private var dragReorderOnly = false                     // a favorites-section drag: reorder, never move folders
    private weak var dragHighlightedHeader: NSView?         // the drop-target header tinted during a move drag
    // Whole-row drag gesture (no visible grip): a press that moves past `dragThreshold` becomes a
    // drag, otherwise it selects on release. Lets the entire row act as the drag handle.
    private var rowDownToken: String?
    private var rowDownPoint: NSPoint = .zero
    private var rowDragging = false
    private let dragThreshold: CGFloat = 4

    // Cross-folder move targets, captured per build: each folder/Ungrouped section's drop band
    // (`folderId == nil` is Ungrouped; Favorites is never a target) and its header view, so a drag
    // that leaves its origin section can highlight and drop onto another section. `dragTargetActive`
    // gates `endDrag` between a move and the within-section reorder.
    private var dropBands: [(folderId: String?, top: CGFloat, bottom: CGFloat, header: NSView)] = []
    private var dragTargetActive = false
    private var dragTargetFolderId: String?

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
        v.wantsLayer = true   // so it can tint as a drag drop target (Ungrouped)
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

    /// A footer action row: a bordered glyph box, a title, and an optional right-aligned shortcut
    /// hint. Shared by "New folder" and "New connection" so they match (#82).
    private func footerRow(glyph: String, title: String, hint: String?, rowH: CGFloat,
                           width w: CGFloat, t: Theme, action: @escaping () -> Void) -> ClickRow {
        let row = ClickRow(bg: nil)
        row.hoverColor = t.hover
        row.onClick = action
        row.frame = NSRect(x: 0, y: 0, width: w, height: rowH)
        let mid = rowH / 2
        let boxSize: CGFloat = z(26)
        let box = BoxView(bg: nil, radius: z(7), border: t.line2)
        box.frame = NSRect(x: z(14), y: mid - boxSize / 2, width: boxSize, height: boxSize)
        box.addSubview(centeredGlyph(glyph, sys(16), t.txt4, in: box.frame.size))
        row.addSubview(box)
        let lblH: CGFloat = z(18)
        let lbl = label(title, sys(11.5), t.txt3)
        lbl.frame = NSRect(x: z(49), y: mid - lblH / 2, width: w - z(49) - z(40), height: lblH)
        row.addSubview(lbl)
        if let hint {
            let h = label(hint, mono(10), t.txt5, align: .right)
            h.frame = NSRect(x: w - z(44), y: mid - lblH / 2, width: z(30), height: lblH)
            row.addSubview(h)
        }
        return row
    }

    /// A collapsible folder section header: a disclosure chevron, the folder name (or its inline
    /// rename editor when `editingFolderId` matches), and a member count. The whole header is one
    /// `ClickRow` — a single click toggles collapse, a quick second click renames (`handleFolderClick`)
    /// — with a right-click menu for Rename / Delete. Captured into `dropBands` so a connection drag
    /// can drop onto it (#82).
    private func folderHeader(id: String, name: String, count: Int, collapsed: Bool,
                              width w: CGFloat, t: Theme) -> ClickRow {
        let row = ClickRow(bg: nil)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 0, y: 0, width: w, height: z(26))
        row.onClick = { [weak self] in self?.handleFolderClick(id) }

        let chevron = label(collapsed ? "▸" : "▾", sys(9), t.txt4)
        chevron.frame = NSRect(x: z(13), y: z(7), width: z(12), height: z(12)); row.addSubview(chevron)

        if editingFolderId == id {
            let editor = folderRenameEditor(name, frame: NSRect(x: z(26), y: z(4), width: w - z(26) - z(34), height: z(18)), t: t)
            row.addSubview(editor)
        } else {
            let nameLabel = label(name, sys(11, .semibold), t.txt3)
            nameLabel.frame = NSRect(x: z(26), y: z(6), width: w - z(26) - z(34), height: z(14))
            row.addSubview(nameLabel)
        }

        let c = label("\(count)", mono(10), t.txt5, align: .right)
        c.frame = NSRect(x: w - z(30), y: z(6), width: z(16), height: z(14)); row.addSubview(c)

        // Right-click → Rename / Delete (the cascade-delete confirm lives in the App layer).
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameFolderMenuAction(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = id
        let remove = NSMenuItem(title: "Delete…", action: #selector(deleteFolderMenuAction(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = id
        menu.addItem(rename); menu.addItem(.separator()); menu.addItem(remove)
        row.menu = menu
        return row
    }

    private func connRow(_ c: Connection, currentFolderId: String?, token: String,
                         width: CGFloat, t: Theme) -> ClickRow {
        let selected = store.selectedConnId == c.id
        let row = ClickRow(bg: selected ? t.accentbg : nil)
        row.hoverColor = t.hover
        row.frame = NSRect(x: 0, y: 0, width: width, height: z(42))

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

        // The whole row is the drag handle (no visible grip). A transparent catcher over the row
        // turns a press-and-move past a small threshold into a drag — reorder within the section, or
        // drop onto another folder/Ungrouped band to move it — while a press that doesn't move
        // selects on release (a quick second select opens). It sits above the labels so the gesture
        // works anywhere on the row; the star hit-zone is added after it so favoriting still works.
        let drag = DragGrip(frame: NSRect(x: 0, y: 0, width: width, height: z(42)))
        drag.onDown = { [weak self] e in self?.rowMouseDown(token, event: e) }
        drag.onDrag = { [weak self] e in self?.rowMouseDragged(event: e) }
        drag.onUp = { [weak self] _ in self?.rowMouseUp(c.id) }
        row.addSubview(drag)

        // Clickable star toggles favorite (independent of the row's select/drag), above the catcher.
        let starHit = ClickRow(radius: z(5))
        starHit.frame = NSRect(x: width - z(30), y: z(8), width: z(24), height: z(26))
        starHit.hoverColor = t.hover
        starHit.onClick = { [weak self] in self?.onToggleFavorite?(c.id) }
        let star = label(c.isFavorite ? "★" : "☆", sys(12), c.isFavorite ? t.accent : t.txt5, align: .center)
        star.frame = NSRect(x: 0, y: z(6), width: z(24), height: z(14))
        starHit.addSubview(star)
        row.addSubview(starHit)

        // Right-click → Connect / Open / Edit / Duplicate / Delete.
        let menu = NSMenu()
        let openTitle = c.kind == .ssh ? "Connect" : "Open in Terminal"
        let connect = NSMenuItem(title: openTitle, action: #selector(connectMenuAction(_:)), keyEquivalent: "")
        connect.target = self; connect.representedObject = c.id
        menu.addItem(connect)
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit…", action: #selector(editMenuAction(_:)), keyEquivalent: "")
        edit.target = self; edit.representedObject = c.id
        // No ellipsis: unlike "Edit…" this acts immediately, with no further UI (#101).
        let copy = NSMenuItem(title: "Duplicate", action: #selector(duplicateMenuAction(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = c.id
        let remove = NSMenuItem(title: "Delete", action: #selector(deleteMenuAction(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = c.id
        menu.addItem(edit); menu.addItem(copy); menu.addItem(remove)
        if let moveItem = moveToFolderMenuItem(connId: c.id, currentFolderId: currentFolderId) {
            menu.addItem(.separator()); menu.addItem(moveItem)
        }
        row.menu = menu
        drag.menu = menu        // the catcher covers most of the row, so it carries the menu too
        starHit.menu = menu
        return row
    }

    /// Holds a "Move to folder…" submenu choice for `moveToFolderMenuAction`. `folderId == nil`
    /// means Ungrouped. A class so it rides `NSMenuItem.representedObject`.
    private final class MoveTarget: NSObject {
        let connId: String
        let folderId: String?
        init(connId: String, folderId: String?) { self.connId = connId; self.folderId = folderId }
    }

    /// A "Move to folder…" parent item whose submenu lists Ungrouped (when the row is in a folder)
    /// plus every folder except the one the row already sits in. `nil` when there's nowhere to move
    /// it (no folders, and already ungrouped). The drag offers the same move; this is the reliable,
    /// always-available path (#82).
    private func moveToFolderMenuItem(connId: String, currentFolderId: String?) -> NSMenuItem? {
        let folders = store.domainFolders
        let others = folders.filter { $0.id.uuidString != currentFolderId }
        let canUngroup = currentFolderId != nil
        guard !others.isEmpty || canUngroup else { return nil }

        let submenu = NSMenu()
        if canUngroup {
            let item = NSMenuItem(title: "Ungrouped", action: #selector(moveToFolderMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = MoveTarget(connId: connId, folderId: nil)
            submenu.addItem(item); submenu.addItem(.separator())
        }
        for folder in others {
            let item = NSMenuItem(title: folder.name, action: #selector(moveToFolderMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = MoveTarget(connId: connId, folderId: folder.id.uuidString)
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Move to folder", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
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
    @objc private func duplicateMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onDuplicate?(id) }
    }
    @objc private func deleteMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onDelete?(id) }
    }

    // MARK: Folder header — collapse, inline rename, menu actions (#82)

    /// A single click toggles the folder's collapse; a quick second click renames it. Timed on the
    /// rail (which survives the collapse rebuild), mirroring `handleRowClick`. The double-click's
    /// second toggle is undone so entering rename doesn't also flip the collapse state.
    private func handleFolderClick(_ id: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastFolderClickId == id, now - lastFolderClickAt <= NSEvent.doubleClickInterval {
            lastFolderClickId = nil
            toggleFolderCollapse(id)   // revert the first click's toggle, then rename
            beginFolderRename(id)
        } else {
            lastFolderClickId = id
            lastFolderClickAt = now
            toggleFolderCollapse(id)
        }
    }

    private func toggleFolderCollapse(_ id: String) {
        if store.collapsedFolderIds.contains(id) {
            store.collapsedFolderIds.remove(id)
        } else {
            store.collapsedFolderIds.insert(id)
        }
    }

    /// Begin inline rename of a folder header. Mirrors `TerminalContainerView.beginRename`: the rename
    /// state is set and a rebuild swaps the name label for an editor.
    private func beginFolderRename(_ id: String) {
        editingFolderId = id
        needsLayout = true
    }

    /// Public entry so the App layer can drop a freshly-created folder straight into rename
    /// (Finder-style: "New folder" appears, already editable).
    func beginRenamingFolder(_ id: String) { beginFolderRename(id) }

    private func commitFolderRename() {
        guard let id = editingFolderId else { return }
        let name = folderEditField?.stringValue ?? ""
        editingFolderId = nil
        folderEditField = nil
        onRenameFolder?(id, name.trimmingCharacters(in: .whitespacesAndNewlines))
        needsLayout = true
    }

    private func cancelFolderRename() {
        guard editingFolderId != nil else { return }
        editingFolderId = nil
        folderEditField = nil
        needsLayout = true
    }

    /// The inline editor swapped in for a folder header's name label. Mirrors
    /// `TerminalContainerView.renameEditor`: borderless, made first responder with all text selected
    /// on the next runloop (so the field is in the view tree first).
    private func folderRenameEditor(_ value: String, frame: NSRect, t: Theme) -> NSTextField {
        let tf = NSTextField(string: value)
        tf.font = sys(11, .semibold)
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.textColor = t.txt
        tf.lineBreakMode = .byTruncatingTail
        tf.delegate = self
        tf.frame = frame
        tf.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
        folderEditField = tf
        DispatchQueue.main.async { [weak self, weak tf] in
            guard let tf, self?.editingFolderId != nil else { return }
            self?.window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }
        return tf
    }

    @objc private func renameFolderMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { beginFolderRename(id) }
    }
    @objc private func deleteFolderMenuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onDeleteFolder?(id) }
    }
    @objc private func moveToFolderMenuAction(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? MoveTarget {
            onMoveConnection?(target.connId, target.folderId)
        }
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
        // Reuse the existing scroll view across rebuilds so its autohiding scroller doesn't flash on
        // every selection (#78), and restore its offset so the list doesn't jump to the top. Keep it
        // out of the blanket teardown; the chrome around it is cheap to recreate.
        let priorListOffset = listScroll?.contentView.bounds.origin
        let keptScroll = listScroll
        subviews.forEach { if $0 !== keptScroll { $0.removeFromSuperview() } }
        let t = store.theme
        layer?.backgroundColor = t.panel.cgColor
        let w = bounds.width
        guard w > 60 else { keptScroll?.removeFromSuperview(); listScroll = nil; return }   // collapsed

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

        // Footer: two stacked action rows — "New folder" above "New connection" (#82).
        let footerRowH: CGFloat = z(44)
        let footerH = footerRowH * 2
        let footer = FlippedView(frame: NSRect(x: 0, y: bounds.height - footerH, width: w, height: footerH))
        let ftBorder = BoxView(bg: t.line)
        ftBorder.frame = NSRect(x: 0, y: 0, width: w, height: z(1)); footer.addSubview(ftBorder)
        let newFolder = footerRow(glyph: "⊞", title: "New folder", hint: nil, rowH: footerRowH, width: w, t: t) {
            [weak self] in self?.onCreateFolder?()
        }
        newFolder.frame.origin.y = 0; footer.addSubview(newFolder)
        let newConn = footerRow(glyph: "+", title: "New connection", hint: "⌘N", rowH: footerRowH, width: w, t: t) {
            [weak self] in self?.onAdd?()
        }
        newConn.frame.origin.y = footerRowH; footer.addSubview(newConn)
        addSubview(footer)

        // Scrollable list. Its document is built by `makeListDocument` so a keystroke can rebuild
        // just the document (keeping the sibling search field focused), not the whole rail. The
        // scroll view itself is reused across rebuilds (created once) so the autohiding scroller
        // doesn't flash on selection (#78); only its frame and document change.
        let top: CGFloat = z(56)
        let scroll = keptScroll ?? {
            let s = NSScrollView()
            s.drawsBackground = false
            s.hasVerticalScroller = true
            s.autohidesScrollers = true
            s.verticalScrollElasticity = .allowed
            return s
        }()
        scroll.frame = NSRect(x: 0, y: top, width: w, height: bounds.height - top - footerH)
        scroll.documentView = makeListDocument(width: w, minHeight: scroll.frame.height, t: t)
        if scroll.superview == nil { addSubview(scroll) }
        listScroll = scroll

        // Restore the user's place across the rebuild, clamped to the new content height so we never
        // land in empty space (mirrors RepoPanelView). Swapping `documentView` resets to the top.
        if let off = priorListOffset, let doc = scroll.documentView {
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: off.x, y: min(off.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Build the (filtered) connection list as a fresh document view. Sections come from the pure
    /// `ConnectionGrouping` rule via `store.connectionSections` — Favorites (pinned), one collapsible
    /// header per user folder (empty folders included as drop targets), then Ungrouped — each narrowed
    /// by the current `searchQuery` via `ConnectionSearch`. The kind-based SSH/LOCAL split is gone (#82).
    private func makeListDocument(width w: CGFloat, minHeight: CGFloat, t: Theme) -> FlippedView {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: z(10)))
        listDoc = doc
        rowsById = [:]; sectionTokensById = [:]; sectionConnIdsById = [:]; sectionTopById = [:]
        rowConnId = [:]; rowFolderById = [:]; dragReorderOnlyById = [:]; dropBands = []
        var y: CGFloat = z(6)

        func place(_ hint: NSView) { hint.frame.origin.y = y; doc.addSubview(hint); y += hint.frame.height + z(4) }

        // Whole-rail empty state: nothing at all to organize.
        if store.domainConnections.isEmpty, store.domainFolders.isEmpty {
            place(emptyHint("No connections yet. Press ⌘N to add an SSH remote or a local folder.",
                            width: w, t: t, tap: { [weak self] in self?.onAdd?() }))
            doc.frame.size.height = max(y, minHeight)
            return doc
        }

        let query = searchQuery
        func keep(_ c: Connection) -> Bool { ConnectionSearch.matches(query: query, in: c.name, c.meta) }

        let sections = store.connectionSections
        let hasFolders = sections.contains { if case .folder = $0.kind { return true }; return false }

        // Lay out one section's connection rows, registering each for drag under a per-row token.
        // Every connection is draggable; `folderId` is the move origin (nil = Ungrouped/Favorites),
        // and `reorderOnly` blocks cross-folder moves (Favorites and the no-folders flat list).
        func rows(_ items: [Connection], folderId: String?, sectionTag: String, reorderOnly: Bool) {
            let connIds = items.map(\.id)
            let tokens = items.map { "\(sectionTag)/\($0.id)" }
            let firstRowTop = y
            for (i, c) in items.enumerated() {
                let token = tokens[i]
                let r = connRow(c, currentFolderId: folderId, token: token, width: w, t: t)
                r.frame.origin.y = y; doc.addSubview(r); y += z(42)
                rowsById[token] = r
                sectionTokensById[token] = tokens
                sectionConnIdsById[token] = connIds
                sectionTopById[token] = firstRowTop
                rowConnId[token] = c.id
                rowFolderById[token] = folderId
                dragReorderOnlyById[token] = reorderOnly
            }
        }

        var shownAnyRow = false
        for section in sections {
            let items = section.connections.filter(keep)
            switch section.kind {
            case .favorites:
                guard !items.isEmpty else { continue }
                let head = sectionHeader("FAVORITES", accentStar: true, count: "\(items.count)", width: w, t: t)
                head.frame.origin.y = y; doc.addSubview(head); y += z(28)
                rows(items, folderId: nil, sectionTag: "fav", reorderOnly: true)
                y += z(8); shownAnyRow = true

            case let .folder(id, name):
                let collapsed = store.collapsedFolderIds.contains(id)
                let header = folderHeader(id: id, name: name, count: section.connections.count,
                                          collapsed: collapsed, width: w, t: t)
                let bandTop = y
                header.frame.origin.y = y; doc.addSubview(header); y += z(28)
                if !collapsed {
                    rows(items, folderId: id, sectionTag: id, reorderOnly: false)
                    shownAnyRow = shownAnyRow || !items.isEmpty
                }
                dropBands.append((folderId: id, top: bandTop, bottom: y, header: header))
                y += z(8)

            case .ungrouped:
                if hasFolders {
                    // A named catch-all section alongside the folders.
                    let header = sectionHeader("UNGROUPED", accentStar: false, count: "\(section.connections.count)", width: w, t: t)
                    let bandTop = y
                    header.frame.origin.y = y; doc.addSubview(header); y += z(28)
                    rows(items, folderId: nil, sectionTag: "ung", reorderOnly: false)
                    dropBands.append((folderId: nil, top: bandTop, bottom: y, header: header))
                    y += z(8)
                } else {
                    // No folders yet: a flat list, no header (the no-folders default, #82).
                    rows(items, folderId: nil, sectionTag: "ung", reorderOnly: true)
                    y += z(8)
                }
                shownAnyRow = shownAnyRow || !items.isEmpty
            }
        }

        if !shownAnyRow, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A live query that matched nothing — distinct from the no-connections state above.
            let shown = query.trimmingCharacters(in: .whitespacesAndNewlines)
            place(emptyHint("No connections match “\(shown)”.", width: w, t: t))
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

    // MARK: Drag — reorder within a section, or move a connection across folders (#82)

    /// The whole connection row is a drag handle. A press records the start; a drag past the
    /// threshold begins the gesture; a release without a drag is a plain select/open click.
    private func rowMouseDown(_ token: String, event: NSEvent) {
        rowDownToken = token
        rowDownPoint = event.locationInWindow
        rowDragging = false
    }
    private func rowMouseDragged(event: NSEvent) {
        guard let token = rowDownToken else { return }
        if !rowDragging {
            let moved = max(abs(event.locationInWindow.x - rowDownPoint.x),
                            abs(event.locationInWindow.y - rowDownPoint.y))
            guard moved >= dragThreshold else { return }
            rowDragging = true
            beginDrag(token, event: event)
        }
        updateDrag(event: event)
    }
    private func rowMouseUp(_ connId: String) {
        if rowDragging { endDrag() } else { handleRowClick(connId) }
        rowDownToken = nil
        rowDragging = false
    }

    private func beginDrag(_ token: String, event: NSEvent) {
        guard let doc = listDoc, let row = rowsById[token],
              let sectionTokens = sectionTokensById[token], let top = sectionTopById[token] else { return }
        draggingId = token
        dragOrder = sectionTokens
        dragSectionTop = top
        dragReorderOnly = dragReorderOnlyById[token] ?? false
        draggingOriginFolderId = rowFolderById[token] ?? nil
        dragTargetActive = false
        dragTargetFolderId = nil
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
        guard let token = draggingId, let doc = listDoc, let row = rowsById[token] else { return }
        let n = dragOrder.count
        let h = z(42)
        let p = doc.convert(event.locationInWindow, from: nil)
        let withinOrigin = p.y >= dragSectionTop && p.y <= dragSectionTop + CGFloat(n) * h

        if dragReorderOnly || withinOrigin {
            // Reorder within the section (#79): clamp the row to the section's slots and reflow.
            clearDropHighlight()
            guard let from = dragOrder.firstIndex(of: token) else { return }
            let minY = dragSectionTop, maxY = dragSectionTop + CGFloat(n - 1) * h
            let newTop = max(minY, min(maxY, p.y - dragGrabDY))
            row.frame.origin.y = newTop
            var target = Int(((newTop + h / 2) - dragSectionTop) / h)
            target = max(0, min(n - 1, target))
            if target != from { dragOrder.insert(dragOrder.remove(at: from), at: target) }
            for (i, rid) in dragOrder.enumerated() where rid != token {
                rowsById[rid]?.frame.origin.y = dragSectionTop + CGFloat(i) * h
            }
        } else {
            // Outside the origin section: the row follows the cursor and we hunt for a drop band on
            // another folder / Ungrouped section to move into.
            row.frame.origin.y = p.y - dragGrabDY
            for (i, rid) in dragOrder.enumerated() where rid != token {
                rowsById[rid]?.frame.origin.y = dragSectionTop + CGFloat(i) * h   // settle origin rows
            }
            if let band = dropBands.first(where: { $0.top <= p.y && p.y < $0.bottom && $0.folderId != draggingOriginFolderId }) {
                if !dragTargetActive || dragTargetFolderId != band.folderId {
                    clearDropHighlight()
                    dragTargetActive = true
                    dragTargetFolderId = band.folderId
                    band.header.layer?.backgroundColor = store.theme.accentbg.cgColor
                    dragHighlightedHeader = band.header
                }
            } else {
                clearDropHighlight()
            }
        }
    }

    private func endDrag() {
        guard let token = draggingId else { return }
        draggingId = nil
        // Snapshot the drop target *before* clearing the highlight — `clearDropHighlight` resets
        // `dragTargetActive`, so reading it after would always miss the move.
        let movedToFolder = dragTargetActive
        let targetFolderId = dragTargetFolderId
        clearDropHighlight()
        dragTargetFolderId = nil
        // A move across folders wins when the drop landed on another section's band; otherwise it's
        // a within-section reorder (a single element shifting slots). Either way the App layer
        // persists and the resulting store update triggers the settling rebuild; a no-op just settles.
        if movedToFolder, let connId = rowConnId[token] {
            onMoveConnection?(connId, targetFolderId)
        } else if let original = sectionConnIdsById[token],
                  let from = sectionTokensById[token]?.firstIndex(of: token),
                  let to = dragOrder.firstIndex(of: token), from != to {
            onReorder?(original.compactMap(UUID.init(uuidString:)), from, to)
        } else {
            repopulateList()
        }
    }

    private func clearDropHighlight() {
        dragHighlightedHeader?.layer?.backgroundColor = nil
        dragHighlightedHeader = nil
        dragTargetActive = false
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

    /// Folder rename: Return commits, Esc cancels. Search field: Esc clears an active filter
    /// instead of AppKit's default "revert" behavior.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === folderEditField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): commitFolderRename(); return true
            case #selector(NSResponder.cancelOperation(_:)): cancelFolderRename(); return true
            default: return false
            }
        }
        guard control === searchField, selector == #selector(NSResponder.cancelOperation(_:)),
              !(searchField?.stringValue.isEmpty ?? true) else { return false }
        searchField?.stringValue = ""
        searchQuery = ""
        repopulateList()
        return true
    }

    /// Clicking away (focus loss) commits a folder rename. Guarded by `editingFolderId` so the
    /// commit-then-rebuild that clears the field can't re-enter. Mirrors `TerminalContainerView`.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard editingFolderId != nil, (obj.object as? NSTextField) === folderEditField else { return }
        commitFolderRename()
    }
}
