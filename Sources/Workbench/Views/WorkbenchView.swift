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
        // The dock owns its terminal sessions (local shells + SSH connection tabs) and their
        // close/title lifecycle; closing the last tab reopens a local one rather than quitting.
        self.terminal = TerminalContainerView(store: store, ghostty: ghostty)

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
        let hbTop = BoxView(bg: t.line); hbTop.frame = NSRect(x: 0, y: 0, width: w, height: 1); header.addSubview(hbTop)
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

        // Resizable bottom region: the connection header sits directly on top of the terminal —
        // so connection name / type / IP / status read as the terminal's own header — with the
        // issue/PR detail filling the space above. Dragging the terminal grip moves the header with
        // it, keeping them together as one resizable unit.
        let maxTerm = max(120, (h - headH) * 0.9)
        let termH = min(max(120, store.terminalHeight), maxTerm)
        let headerY = max(0, h - termH - headH)
        detail.frame = NSRect(x: 0, y: 0, width: w, height: headerY)
        header.frame = NSRect(x: 0, y: headerY, width: w, height: headH)
        terminal.frame = NSRect(x: 0, y: h - termH, width: w, height: termH)

        detail.apply()
        terminal.apply()
    }
}

/// Root content view: titlebar + three columns + settings overlay.
final class WorkbenchView: NSView {
    let store: Store
    let ghostty: GhosttyApp
    private let connections: ConnectionServices
    private let auth: GitHubAuthController
    private let data: GitHubDataController
    private let titlebar: TitlebarView
    private let rail: ConnectionRailView
    private let center: CenterColumnView
    private let repoPanel: RepoPanelView
    private var settings: SettingsPopover?
    private var newConn: NewConnectionSheet?
    private var manageOrgs: ManageOrgsSheet?
    private var deviceFlow: DeviceFlowSheet?
    /// Mirrors `store.railCollapsed` so `onChange` can tell a sidebar toggle apart from every other
    /// notify (theme, selection, data) and animate only that transition. Seeded from the store so a
    /// restored collapsed state on launch lays out instantly rather than sliding in.
    private var railShown: Bool

    override var isFlipped: Bool { true }

    init(store: Store, ghostty: GhosttyApp, connections: ConnectionServices,
         auth: GitHubAuthController, data: GitHubDataController) {
        self.store = store
        self.ghostty = ghostty
        self.connections = connections
        self.auth = auth
        self.data = data
        self.titlebar = TitlebarView(store: store)
        self.rail = ConnectionRailView(store: store)
        self.center = CenterColumnView(store: store, ghostty: ghostty)
        self.repoPanel = RepoPanelView(store: store)
        self.railShown = store.railCollapsed
        super.init(frame: NSRect(x: 0, y: 0, width: 1340, height: 880))
        wantsLayer = true

        // Rail sits above the center/repo columns (but below the titlebar) so that when it slides in/out
        // it passes over them instead of being clipped behind. They never overlap when docked, so the
        // order is cosmetic except during the slide.
        addSubview(center)
        addSubview(repoPanel)
        addSubview(rail)
        addSubview(titlebar)

        titlebar.onToggleSidebar = { [weak self] in self?.store.railCollapsed.toggle() }
        titlebar.onToggleSettings = { [weak self] in self?.store.settingsOpen.toggle() }

        rail.onAdd = { [weak self] in self?.openSheet(editingId: nil) }
        rail.onEdit = { [weak self] id in self?.openSheet(editingId: id) }
        rail.onDelete = { [weak self] id in self?.deleteConnection(id) }
        rail.onToggleFavorite = { [weak self] id in self?.toggleFavorite(id) }
        rail.onConnect = { [weak self] id in self?.connect(id) }

        repoPanel.onSelectRepo = { [weak self] owner, name in self?.data.selectRepo(owner: owner, name: name) }
        repoPanel.onSelectItem = { [weak self] number in self?.data.selectItem(number: number) }
        repoPanel.onManageOrgs = { [weak self] in self?.store.manageOrgsOpen = true }
        center.detail.onSubmitComment = { [weak self] body, done in self?.data.submitComment(body: body, completion: done) }

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
                                    kind: connection.kind, isFavorite: connection.isFavorite,
                                    customCommand: connection.customCommand)
        Task { _ = try? await save(draft) }
    }

    private func applyTheme() {
        layer?.backgroundColor = store.theme.win.cgColor
        titlebar.apply(); rail.apply(); center.apply(); repoPanel.apply()
        // Re-skin the live libghostty surfaces too; the dock chrome repaints via center.apply().
        // Guarded internally so non-theme notifies (selection, data) are a cheap no-op.
        center.terminal.syncTerminalTheme()
        needsLayout = true
    }

    /// Animate *only* the connection rail. We commit the final layout with no animation — the center
    /// column and repo panel reflow once to their final size and never animate — then translate just the
    /// rail view between its docked position (x = 0) and its off-screen position (x = -railWidth). The
    /// rail keeps a constant width, so sliding it moves the whole panel as one unit without reflowing its
    /// contents. (Wrapping the whole subtree in `allowsImplicitAnimation` instead animated every column
    /// and cross-faded their rebuilt contents — the "everything re-renders" behaviour we don't want.)
    private func slideRail() {
        let from = rail.frame
        layoutSubtreeIfNeeded()
        let to = rail.frame
        guard from != to else { return }
        rail.frame = from
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            rail.animator().frame = to
        }
    }

    private func onChange() {
        applyTheme()
        // Slide only the rail when the sidebar is toggled. Gated on the actual collapse flip so
        // theme/selection/data notifies and window resizes still lay out instantly.
        if store.railCollapsed != railShown {
            railShown = store.railCollapsed
            slideRail()
        }
        // Settings overlay show/hide.
        if store.settingsOpen, settings == nil {
            let pop = SettingsPopover(store: store, auth: auth)
            pop.onClose = { [weak self] in self?.store.settingsOpen = false }
            pop.frame = bounds
            addSubview(pop)
            settings = pop
        } else if !store.settingsOpen, let pop = settings {
            pop.removeFromSuperview()
            settings = nil
        }
        settings?.needsLayout = true

        // Device-flow sign-in sheet show/hide. Active for every non-terminal auth state.
        let authActive: Bool
        switch store.authState {
        case .authenticatingPending, .authenticating, .authError: authActive = true
        case .signedOut, .signedIn: authActive = false
        }
        if authActive, deviceFlow == nil {
            let sheet = DeviceFlowSheet(store: store, auth: auth)
            sheet.onClose = { [weak self] in self?.auth.cancel() }
            sheet.frame = bounds
            addSubview(sheet)
            deviceFlow = sheet
        } else if !authActive, let sheet = deviceFlow {
            sheet.removeFromSuperview()
            deviceFlow = nil
            focusTerminal()
        }
        deviceFlow?.needsLayout = true

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

        // Manage-organizations sheet show/hide.
        if store.manageOrgsOpen, manageOrgs == nil {
            let sheet = ManageOrgsSheet(store: store)
            sheet.onClose = { [weak self] in self?.store.manageOrgsOpen = false }
            sheet.frame = bounds
            addSubview(sheet)
            manageOrgs = sheet
        } else if !store.manageOrgsOpen, let sheet = manageOrgs {
            sheet.removeFromSuperview()
            manageOrgs = nil
            focusTerminal()
        }
        manageOrgs?.needsLayout = true
    }

    func focusTerminal() {
        // Only the live libghostty surface takes keystrokes; the error placeholder must not grab focus.
        guard let term = center.terminal.activeSurfaceView else { return }
        window?.makeFirstResponder(term)
    }

    /// Open a console tab for a connection. SSH connections launch `ssh [user@]host`; local-folder
    /// connections open a shell in that directory.
    private func connect(_ id: String) {
        guard let uuid = UUID(uuidString: id),
              let conn = store.domainConnections.first(where: { $0.id == uuid }) else { return }
        switch conn.kind {
        case let .ssh(host, port, user):
            let command = SSHCommand.command(host: host, port: port, user: user, custom: conn.customCommand)
            center.terminal.openConnection(command: command, title: conn.name)
        case let .localFolder(path):
            let dir = (path as NSString).expandingTildeInPath
            center.terminal.openConnection(workingDirectory: dir, title: conn.name)
        }
        store.selectedConnId = id
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // A touch taller than the standard 28pt titlebar for breathing room; the titlebar's own
        // icons stay anchored to the traffic-light line (see TitlebarView), so they remain aligned
        // with close/minimise/zoom rather than drifting to the taller bar's centre.
        let barH: CGFloat = 34
        titlebar.frame = NSRect(x: 0, y: 0, width: w, height: barH)
        let rowY = barH, rowH = h - barH
        // The rail keeps a fixed 266pt width and is parked off-screen to the left when collapsed, so a
        // toggle is a pure horizontal slide of the panel. `railSpace` is the gap it leaves for the center
        // column: 0 when collapsed (center reclaims the room), 266 when docked.
        let railWidth: CGFloat = 266
        let railSpace: CGFloat = store.railCollapsed ? 0 : railWidth
        rail.frame = NSRect(x: store.railCollapsed ? -railWidth : 0, y: rowY, width: railWidth, height: rowH)
        repoPanel.frame = NSRect(x: w - 312, y: rowY, width: 312, height: rowH)
        center.frame = NSRect(x: railSpace, y: rowY, width: max(0, w - railSpace - 312), height: rowH)
        settings?.frame = bounds
        newConn?.frame = bounds
        manageOrgs?.frame = bounds
        deviceFlow?.frame = bounds
    }
}
