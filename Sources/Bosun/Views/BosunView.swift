import AppKit
import Application
import Domain

/// Center column: scrollable detail + docked terminal. Connection name/type live in the
/// macOS titlebar (see TitlebarView), so the center column carries no header of its own.
final class CenterColumnView: FlippedView {
    let store: Store
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
        terminal.onRelayout = { [weak self] in self?.needsLayout = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }

    override func layout() {
        super.layout()
        let t = store.theme
        layer?.backgroundColor = t.win.cgColor
        let w = bounds.width, h = bounds.height

        // Resizable bottom region: the docked terminal sits at the bottom with its own drag grip
        // on its top edge, and the issue/PR detail pane fills everything above it down to that grip.
        let maxTerm = max(120, h * 0.9)
        let termH = min(max(120, store.terminalHeight), maxTerm)
        detail.frame = NSRect(x: 0, y: 0, width: w, height: h - termH)
        terminal.frame = NSRect(x: 0, y: h - termH, width: w, height: termH)

        detail.apply()
        terminal.apply()
    }
}

/// Root content view: titlebar + three columns + settings overlay.
final class BosunView: NSView {
    let store: Store
    let ghostty: GhosttyApp
    private let connections: ConnectionServices
    private let auth: GitHubAuthController
    private let data: GitHubDataController
    private let titlebar: TitlebarView
    private let rail: ConnectionRailView
    private let center: CenterColumnView
    private let repoPanel: RepoPanelView
    private var settings: SettingsSheet?
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

        rail.onAdd = { [weak self] in self?.openSheet(editingId: nil) }
        rail.onEdit = { [weak self] id in self?.openSheet(editingId: id) }
        rail.onDelete = { [weak self] id in self?.deleteConnection(id) }
        rail.onToggleFavorite = { [weak self] id in self?.toggleFavorite(id) }
        rail.onConnect = { [weak self] id in self?.connect(id) }

        repoPanel.onSelectRepo = { [weak self] owner, name in self?.data.selectRepo(owner: owner, name: name) }
        repoPanel.onSelectItem = { [weak self] number in self?.data.selectItem(number: number) }
        repoPanel.onManageOrgs = { [weak self] in self?.store.manageOrgsOpen = true }
        repoPanel.onChangeFilter = { [weak self] in self?.data.reloadCurrentItems() }
        repoPanel.onChangeGroup = { [weak self] in self?.data.loadBlockedByIfNeeded() }
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
        // Settings sheet show/hide.
        if store.settingsOpen, settings == nil {
            let sheet = SettingsSheet(store: store, auth: auth)
            sheet.onClose = { [weak self] in self?.store.settingsOpen = false }
            sheet.frame = bounds
            addSubview(sheet)
            settings = sheet
        } else if !store.settingsOpen, let sheet = settings {
            sheet.removeFromSuperview()
            settings = nil
            focusTerminal()
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
    /// connections open a shell in that directory. The dock builds the command from the connection.
    private func connect(_ id: String) {
        guard let uuid = UUID(uuidString: id),
              let conn = store.domainConnections.first(where: { $0.id == uuid }) else { return }
        center.terminal.openConnection(conn)
        store.selectedConnId = id
    }

    /// Reopen the terminal tabs saved from the last session (called once connections are loaded).
    func restoreTerminalTabs() {
        center.terminal.restoreTabs(connections: store.domainConnections)
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
