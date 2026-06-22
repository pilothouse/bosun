import AppKit
import Application
import Domain

/// Center column: connection header + scrollable detail + docked terminal.
final class CenterColumnView: FlippedView {
    let store: Store
    private let header = FlippedView()
    let detail: DetailView
    let terminal: TerminalContainerView

    init(store: Store, ghostty: GhosttyApp) {
        self.store = store
        self.detail = DetailView(store: store)

        let surface: NSView
        if ghostty.availability.isReady, let app = ghostty.app {
            surface = GhosttySurfaceView(app: app)
        } else if case .unavailable(let stage) = ghostty.availability {
            surface = TerminalUnavailableView(stage: stage)
        } else {
            // Ready but no surface — shouldn't happen; show an error state rather than a dead pane.
            surface = TerminalUnavailableView(stage: .application)
        }
        self.terminal = TerminalContainerView(store: store, terminal: surface,
                                              available: ghostty.availability.isReady)

        super.init(frame: .zero)
        wantsLayer = true
        addSubview(detail)
        addSubview(terminal)
        addSubview(header)
        header.wantsLayer = true
        terminal.onRelayout = { [weak self] in self?.needsLayout = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }

    override func layout() {
        super.layout()
        let t = store.theme
        layer?.backgroundColor = t.win.cgColor
        let w = bounds.width, h = bounds.height

        // Header.
        let headH: CGFloat = 44
        header.frame = NSRect(x: 0, y: 0, width: w, height: headH)
        header.layer?.backgroundColor = t.win.cgColor
        header.subviews.forEach { $0.removeFromSuperview() }
        let hb = BoxView(bg: t.line); hb.frame = NSRect(x: 0, y: headH - 1, width: w, height: 1); header.addSubview(hb)
        let conn = store.selectedConn
        var hx: CGFloat = 18
        let glyph = label(conn.glyph, sys(13), t.txt3); glyph.frame = NSRect(x: hx, y: 13, width: 16, height: 16); header.addSubview(glyph); hx += 22
        let nm = label(conn.name, sys(13.5, .bold), t.txt); nm.frame = NSRect(x: hx, y: 12, width: fitW(nm), height: 18); header.addSubview(nm); hx += nm.frame.width + 10
        let kb = badge(conn.kindLabel, fg: conn.dot, border: conn.dot); kb.frame.origin = NSPoint(x: hx, y: 13); header.addSubview(kb)
        // Right meta.
        let sess = label(conn.sessionLabel, mono(10.5), conn.dot, align: .right)
        sess.frame = NSRect(x: w - 230, y: 14, width: 214, height: 14); header.addSubview(sess)
        let sd = Dot(conn.dot, 6); sd.frame.origin = NSPoint(x: w - 244, y: 19); header.addSubview(sd)
        let meta = label(conn.meta, mono(10.5), t.txt4, align: .right)
        meta.frame = NSRect(x: w - 470, y: 14, width: 210, height: 14); header.addSubview(meta)

        // Terminal (bottom) + detail (middle).
        let maxTerm = max(120, (h - headH) * 0.9)
        let termH = min(max(120, store.terminalHeight), maxTerm)
        terminal.frame = NSRect(x: 0, y: h - termH, width: w, height: termH)
        detail.frame = NSRect(x: 0, y: headH, width: w, height: h - headH - termH)

        detail.apply()
        terminal.apply()
    }
}

/// Root content view: titlebar + three columns + settings overlay.
final class WorkbenchView: NSView {
    let store: Store
    let ghostty: GhosttyApp
    private let connections: ConnectionServices
    private let titlebar: TitlebarView
    private let rail: ConnectionRailView
    private let center: CenterColumnView
    private let repoPanel: RepoPanelView
    private var settings: SettingsPopover?
    private var newConn: NewConnectionSheet?

    override var isFlipped: Bool { true }

    init(store: Store, ghostty: GhosttyApp, connections: ConnectionServices) {
        self.store = store
        self.ghostty = ghostty
        self.connections = connections
        self.titlebar = TitlebarView(store: store)
        self.rail = ConnectionRailView(store: store)
        self.center = CenterColumnView(store: store, ghostty: ghostty)
        self.repoPanel = RepoPanelView(store: store)
        super.init(frame: NSRect(x: 0, y: 0, width: 1340, height: 880))
        wantsLayer = true

        addSubview(rail)
        addSubview(center)
        addSubview(repoPanel)
        addSubview(titlebar)

        titlebar.onToggleSidebar = { [weak self] in self?.store.railCollapsed.toggle() }
        titlebar.onToggleSettings = { [weak self] in self?.store.settingsOpen.toggle() }

        rail.onAdd = { [weak self] in self?.openSheet(editingId: nil) }
        rail.onEdit = { [weak self] id in self?.openSheet(editingId: id) }
        rail.onDelete = { [weak self] id in self?.deleteConnection(id) }
        rail.onToggleFavorite = { [weak self] id in self?.toggleFavorite(id) }

        store.observe { [weak self] in self?.onChange() }
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Connection flow

    private func openSheet(editingId: String?) {
        store.editingConnId = editingId
        store.newConnectionOpen = true
    }

    private func upsert(_ connection: Domain.Connection) {
        if let idx = store.domainConnections.firstIndex(where: { $0.id == connection.id }) {
            store.domainConnections[idx] = connection
        } else {
            store.domainConnections.append(connection)
        }
        store.selectedConnId = connection.id.uuidString
    }

    private func deleteConnection(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        store.domainConnections.removeAll { $0.id == uuid }
        if store.selectedConnId == id {
            store.selectedConnId = store.domainConnections.first?.id.uuidString ?? ""
        }
        let remove = connections.remove
        Task { try? await remove(id: uuid) }
    }

    private func toggleFavorite(_ id: String) {
        guard let uuid = UUID(uuidString: id),
              let idx = store.domainConnections.firstIndex(where: { $0.id == uuid }) else { return }
        var connection = store.domainConnections[idx]
        connection.isFavorite.toggle()
        store.domainConnections[idx] = connection
        let save = connections.save
        let draft = ConnectionDraft(id: connection.id, name: connection.name,
                                    kind: connection.kind, isFavorite: connection.isFavorite)
        Task { _ = try? await save(draft) }
    }

    private func applyTheme() {
        layer?.backgroundColor = store.theme.win.cgColor
        titlebar.apply(); rail.apply(); center.apply(); repoPanel.apply()
        needsLayout = true
    }

    private func onChange() {
        applyTheme()
        // Settings overlay show/hide.
        if store.settingsOpen, settings == nil {
            let pop = SettingsPopover(store: store)
            pop.onClose = { [weak self] in self?.store.settingsOpen = false }
            pop.frame = bounds
            addSubview(pop)
            settings = pop
        } else if !store.settingsOpen, let pop = settings {
            pop.removeFromSuperview()
            settings = nil
        }
        settings?.needsLayout = true

        // New-connection sheet show/hide.
        if store.newConnectionOpen, newConn == nil {
            let editing = store.editingConnId.flatMap { id in
                store.domainConnections.first { $0.id.uuidString == id }
            }
            let sheet = NewConnectionSheet(store: store, save: connections.save, editing: editing)
            sheet.onSaved = { [weak self] connection in
                self?.upsert(connection)
                self?.store.newConnectionOpen = false
            }
            sheet.onClose = { [weak self] in self?.store.newConnectionOpen = false }
            sheet.frame = bounds
            addSubview(sheet)
            newConn = sheet
        } else if !store.newConnectionOpen, let sheet = newConn {
            sheet.removeFromSuperview()
            newConn = nil
            focusTerminal()
        }
        newConn?.needsLayout = true
    }

    func focusTerminal() {
        // Only the live libghostty surface takes keystrokes; the error placeholder must not grab focus.
        guard let term = center.terminal.terminalView as? GhosttySurfaceView else { return }
        window?.makeFirstResponder(term)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        titlebar.frame = NSRect(x: 0, y: 0, width: w, height: 44)
        let rowY: CGFloat = 44, rowH = h - 44
        let railW: CGFloat = store.railCollapsed ? 0 : 266
        rail.frame = NSRect(x: 0, y: rowY, width: railW, height: rowH)
        repoPanel.frame = NSRect(x: w - 312, y: rowY, width: 312, height: rowH)
        center.frame = NSRect(x: railW, y: rowY, width: max(0, w - railW - 312), height: rowH)
        settings?.frame = bounds
        newConn?.frame = bounds
    }
}
