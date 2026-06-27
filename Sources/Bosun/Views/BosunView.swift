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

        // `terminalLeading` puts the terminal first (top/left) instead of the default trailing
        // (bottom/right); the detail pane takes the remaining space. The drag grip lives on the
        // shared border either way (see TerminalContainerView).
        let leading = store.terminalLeading
        switch store.splitAxis {
        case .vertical:
            // Stacked: the terminal is sized in pixels and the detail pane fills the rest. The same
            // Domain clamp the drag uses keeps both panes above their floor, so neither collapses to
            // zero and the terminal isn't capped on a tall display (#65).
            let termH = CGFloat(SplitLayout.clampExtent(Double(store.terminalHeight), total: Double(h)))
            let termY = leading ? 0 : h - termH
            let detailY = leading ? termH : 0
            terminal.frame = NSRect(x: 0, y: termY, width: w, height: termH)
            detail.frame = NSRect(x: 0, y: detailY, width: w, height: h - termH)
        case .horizontal:
            // Side by side: the terminal is sized as a fraction of the width (clamped by SplitLayout)
            // so it tracks the column's width as the sidebar/orgs panel collapse.
            let termW = CGFloat(SplitLayout.terminalExtent(total: Double(w), fraction: Double(store.terminalFraction)))
            let termX = leading ? 0 : w - termW
            let detailX = leading ? termW : 0
            terminal.frame = NSRect(x: termX, y: 0, width: termW, height: h)
            detail.frame = NSRect(x: detailX, y: 0, width: max(0, w - termW), height: h)
        }

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
    /// Twin of `railShown` for the right organizations panel — see `slidePanel()`.
    private var panelShown: Bool

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
        self.panelShown = store.repoPanelCollapsed
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
        titlebar.onTogglePanel = { [weak self] in self?.store.repoPanelCollapsed.toggle() }
        titlebar.onToggleSplitAxis = { [weak self] in
            guard let self else { return }
            self.store.splitAxis = self.store.splitAxis.toggled
        }
        titlebar.onSwapSides = { [weak self] in self?.store.terminalLeading.toggle() }
        titlebar.onRefresh = { [weak self] in self?.data.refresh() }

        rail.onAdd = { [weak self] in self?.openSheet(editingId: nil) }
        rail.onEdit = { [weak self] id in self?.openSheet(editingId: id) }
        rail.onDelete = { [weak self] id in self?.deleteConnection(id) }
        rail.onToggleFavorite = { [weak self] id in self?.toggleFavorite(id) }
        rail.onConnect = { [weak self] id in self?.connect(id) }

        repoPanel.onSelectRepo = { [weak self] owner, name in self?.data.selectRepo(owner: owner, name: name) }
        repoPanel.onSelectOrg = { [weak self] id in self?.data.selectOrg(id: id) }
        repoPanel.onSelectItem = { [weak self] item in self?.data.selectItem(item) }
        repoPanel.onManageOrgs = { [weak self] in self?.store.manageOrgsOpen = true }
        repoPanel.onChangeFilter = { [weak self] in self?.data.reloadCurrentItems() }
        repoPanel.onChangeGroup = { [weak self] in self?.data.loadBlockedByIfNeeded() }
        center.detail.onSubmitComment = { [weak self] body, done in self?.data.submitComment(body: body, completion: done) }
        center.detail.onRefreshDetail = { [weak self] in self?.data.refreshDetail() }

        // Reflect the active console tab — or its label — wherever it's shown whenever it changes (#73).
        center.terminal.onActiveTitleChange = { [weak self] in self?.updateActiveConsoleTitle() }

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
        // Re-skin and re-size the live libghostty surfaces too; the dock chrome repaints via
        // center.apply(). Guarded internally so notifies that change neither the theme nor the zoom
        // (selection, data) are a cheap no-op.
        center.terminal.syncTerminal()
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

    /// Mirror of `slideRail()` for the right organizations panel: commit the final layout (the center
    /// column reflows once to its new width), then translate only the panel between its docked
    /// position (x = w - width) and its off-screen position (x = w).
    private func slidePanel() {
        let from = repoPanel.frame
        layoutSubtreeIfNeeded()
        let to = repoPanel.frame
        guard from != to else { return }
        repoPanel.frame = from
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            repoPanel.animator().frame = to
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
        if store.repoPanelCollapsed != panelShown {
            panelShown = store.repoPanelCollapsed
            slidePanel()
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

    /// Reflect the active console tab's label (#73) in both places it shows: the macOS window title
    /// (`NSWindow.title`, for Mission Control / the Dock window list) and the titlebar breadcrumb's
    /// last segment. The label already identifies the console — the connection name for a connection
    /// tab (locked, so the server's OSC title can't overwrite it, per `TerminalTitlePolicy` / #29), or
    /// the shell/cwd for a local tab — so switching or renaming the active tab updates both. The
    /// titlebar is relaid out directly (not via `store.notify`) to avoid a full UI rebuild per update.
    private func updateActiveConsoleTitle() {
        let console = center.terminal.activeTabTitle
        store.onWindowTitle?(Domain.WindowTitlePolicy.title(console: console))
        store.activeConsoleTitle = console ?? ""
        titlebar.apply()
    }

    /// Focus the connection-rail search field (the ⌘K target). The field exists only when the rail is
    /// expanded, so expand it first; the rebuild that follows happens on the next runloop tick, so we
    /// defer the focus until the field has been recreated.
    func focusConnectionSearch() {
        if store.railCollapsed { store.railCollapsed = false }
        DispatchQueue.main.async { [weak self] in self?.rail.focusSearch() }
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

    /// Console-only terminal font zoom (⌥⌘+ / ⌥⌘− / ⌥⌘0), routed from the View menu to the focused
    /// surface — independent of the global ⌘± zoom, which scales the whole UI and the terminal together.
    func zoomTerminalIn() { center.terminal.zoomActiveTerminalIn() }
    func zoomTerminalOut() { center.terminal.zoomActiveTerminalOut() }
    func zoomTerminalReset() { center.terminal.resetActiveTerminalZoom() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // A touch taller than the standard 28pt titlebar for breathing room; the titlebar's own
        // icons stay anchored to the traffic-light line (see TitlebarView), so they remain aligned
        // with close/minimise/zoom rather than drifting to the taller bar's centre.
        // Titlebar height scales with the UI zoom so the (globally scaled) breadcrumb/icons fit; the
        // sidebar and orgs panel scale their fixed widths the same way so their scaled contents fit.
        let barH: CGFloat = z(34)
        titlebar.frame = NSRect(x: 0, y: 0, width: w, height: barH)
        let rowY = barH, rowH = h - barH
        // The rail keeps a fixed 266pt width (× zoom) and is parked off-screen to the left when
        // collapsed, so a toggle is a pure horizontal slide of the panel. `railSpace` is the gap it
        // leaves for the center column: 0 when collapsed (center reclaims the room), else its width.
        let railWidth: CGFloat = z(266)
        let railSpace: CGFloat = store.railCollapsed ? 0 : railWidth
        rail.frame = NSRect(x: store.railCollapsed ? -railWidth : 0, y: rowY, width: railWidth, height: rowH)
        // The repo panel mirrors the rail: fixed 312pt width (× zoom), parked off-screen to the right
        // (x = w) when collapsed so a toggle is a pure horizontal slide. `panelSpace` is the gap it
        // leaves for the center column: 0 when collapsed (center reclaims the room), else its width.
        let panelWidth: CGFloat = z(312)
        let panelSpace: CGFloat = store.repoPanelCollapsed ? 0 : panelWidth
        repoPanel.frame = NSRect(x: store.repoPanelCollapsed ? w : w - panelWidth, y: rowY, width: panelWidth, height: rowH)
        center.frame = NSRect(x: railSpace, y: rowY, width: max(0, w - railSpace - panelSpace), height: rowH)
        settings?.frame = bounds
        newConn?.frame = bounds
        manageOrgs?.frame = bounds
        deviceFlow?.frame = bounds
    }
}
