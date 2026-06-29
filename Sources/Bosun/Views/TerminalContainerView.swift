import AppKit
import Domain

/// What a tab represents, so it can be reopened on relaunch: a plain local shell, or a saved
/// connection (keyed by `Connection.id`, re-resolved at restore). See `TerminalTabState`.
enum TabOrigin: Equatable {
    case local
    case connection(String)   // Connection.id.uuidString
}

/// One terminal tab: a live libghostty surface (or the unavailable placeholder) plus its label.
final class TerminalSession {
    let id = UUID()
    let view: NSView
    var title: String
    var dot: NSColor
    /// Where this tab came from, used to persist + reopen it. See `TerminalContainerView.snapshotTabs`.
    let origin: TabOrigin
    /// When set, the server/OSC title is ignored so the tab keeps `title` (issue #29). True for
    /// named-connection tabs; `var` so a user-renamed local tab can lock too (#30).
    var lockTitle: Bool
    /// Ephemeral activity flag: this tab rang the bell / posted a notification while in the
    /// background (#74). Drives the amber badge in `tabView`; cleared on focus. Not persisted —
    /// kept out of `TerminalTabState` / `snapshotTabs`.
    var hasBell = false
    /// Ephemeral busy flag: the surface reported it's working (an in-flight OSC 9;4 progress report),
    /// cleared when it reports done or its shell command finishes (#93). Drives the spinner-for-dot
    /// swap in `tabView` when `store.terminalBusySpinner` is on. Live state, *not* cleared on focus
    /// (unlike `hasBell`) and not persisted.
    var isBusy = false
    /// Whether the spinner is actually drawn. Lags `isBusy` by a short debounce so a fast command
    /// (e.g. `ls`) that flips busy for a few ms via the shell hook (#94) doesn't flicker the tab;
    /// `busyDebounce` is the pending "show" work item, cancelled if the command finishes first.
    var busyShown = false
    var busyDebounce: DispatchWorkItem?

    init(view: NSView, title: String, dot: NSColor, origin: TabOrigin, lockTitle: Bool = false) {
        self.view = view
        self.title = title
        self.dot = dot
        self.origin = origin
        self.lockTitle = lockTitle
    }

    var surfaceView: GhosttySurfaceView? { view as? GhosttySurfaceView }
}

/// Terminal dock: live tab strip + the active libghostty surface. Order and active selection are
/// delegated to the pure `TerminalTabs` model (unit-tested in Domain); this view only owns the
/// id→surface mapping and the AppKit chrome. The detail↔terminal resize grip is owned by the split
/// container (`CenterColumnView`), not this view (#84). Closing the last tab opens a fresh local one
/// so the dock is never empty and `exit` never quits the app.
final class TerminalContainerView: FlippedView {
    let store: Store
    private let ghostty: GhosttyApp
    private let available: Bool

    /// Ordering + which tab is active — the tested rule lives in Domain.
    private var tabs = TerminalTabs<UUID>()
    /// id → session (the surface view + label). Kept in sync with `tabs.ids`.
    private var views: [UUID: TerminalSession] = [:]

    /// Inline-rename state (#30). Lives on the container, not the tab row, because the strip is
    /// rebuilt on every `layout()` — the row that received the first click no longer exists by the
    /// second. `editingTabId` is the tab currently in edit mode; `editField` is its live editor;
    /// `lastTabClick*` time a double-click the same way `ConnectionRailView` does.
    private var editingTabId: UUID?
    private weak var editField: NSTextField?
    private var lastTabClickId: UUID?
    private var lastTabClickAt: TimeInterval = 0

    /// Whole-tab drag-reorder (#87), modelled on `ConnectionRailView`'s row drag (#79): a press past
    /// `tabDragThreshold` becomes a reorder; a release without a drag is a plain select/rename click.
    /// `dragTabOrder` is a live copy of `tabs.ids` mutated during the drag; `tabRowsById`/`tabDoc`
    /// are the current strip rows + their scrolling document, rebuilt every `layout()`.
    private var tabDownId: UUID?
    private var tabDownPoint: NSPoint = .zero
    private var tabDragging = false
    private let tabDragThreshold: CGFloat = 4
    private var draggingTabId: UUID?
    private var dragTabOrder: [UUID] = []
    private var dragTabGrabDX: CGFloat = 0
    private var tabRowsById: [UUID: ClickRow] = [:]
    private weak var tabDoc: FlippedView?

    /// Horizontal-scroll state for the tab strip (#21). The strip is rebuilt every `layout()`, so the
    /// scroll view is too; `tabScroll` is the live one (weak — it's owned by the bar) read at the top
    /// of the next `layout()` to carry the user's manual scroll offset across a plain repaint.
    /// `lastFocusedTabId` is the tab we last auto-scrolled into view, so we only reveal the active tab
    /// when it actually changes (not on every relabel) — the same shape as `RepoPanelView.focusedItemId`.
    private weak var tabScroll: NSScrollView?
    private var lastFocusedTabId: UUID?

    var onRelayout: (() -> Void)?
    /// Fired when the active tab changes or the active tab's label changes, so the App layer can
    /// retitle the window (#73). Lighter than `onRelayout` — it never triggers a parent relayout.
    var onActiveTitleChange: (() -> Void)?

    /// The theme key, zoom level, and terminal options whose config was last pushed to libghostty.
    /// `syncTerminal` runs on every store notify (selection, data, …), so these let it skip the config
    /// rebuild unless the theme, the UI zoom, or a terminal setting (#67) actually changed. Seeded to
    /// the defaults the first surface is created with in `GhosttyApp.start()` (default palette, 100%
    /// zoom, default terminal options).
    private var lastThemeKey = "operator"
    private var lastZoomPercent = 100
    /// The terminal options last pushed to the surfaces (#67); seeded to the same defaults the first
    /// surface is built with, so it only rebuilds when the user actually changes a terminal setting.
    private var lastTerminalConfig = TerminalConfig()

    init(store: Store, ghostty: GhosttyApp) {
        self.store = store
        self.ghostty = ghostty
        self.available = ghostty.availability.isReady
        super.init(frame: .zero)
        wantsLayer = true

        // Seed the dock with one session. When libghostty is down, that's the error placeholder.
        // Persisted tabs (if any) replace this seed once connections load, via `restoreTabs`.
        if available {
            register(makeLocalSession())
        } else if case .unavailable(let stage) = ghostty.availability {
            register(TerminalSession(view: TerminalUnavailableView(stage: stage),
                                     title: "terminal", dot: Status.red, origin: .local))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }

    /// Re-skin and re-size the live terminal to the current theme and UI zoom: rebuild the libghostty
    /// config (the palette *and* the zoom-scaled `font-size`, both baked in by `GhosttyApp.makeConfig`)
    /// and push it to the app + every open surface, so a ⌘+/⌘− re-syncs every terminal to the global
    /// zoom in lockstep with the rest of the GUI. A no-op unless the theme or the zoom changed since
    /// the last push, so it stays cheap on the general theme/relayout path (issue #9). The dock chrome
    /// re-reads the theme/zoom in `layout()`, so it updates separately via `apply()`.
    func syncTerminal() {
        let zoom = store.uiZoom.percent
        guard available, store.themeKey != lastThemeKey || zoom != lastZoomPercent
            || terminalConfig != lastTerminalConfig else { return }
        lastThemeKey = store.themeKey
        lastZoomPercent = zoom
        lastTerminalConfig = terminalConfig
        guard let cfg = ghostty.applyPalette(store.theme.terminalPalette) else { return }
        for session in views.values { session.surfaceView?.updateConfig(cfg) }
        ghostty.tick()   // nudge a repaint with the new colors/size
    }

    var activeSurfaceView: GhosttySurfaceView? {
        tabs.activeID.flatMap { views[$0]?.surfaceView }
    }

    /// The active tab's current label, for the macOS window title (#73). `nil` when the dock is empty.
    var activeTabTitle: String? {
        tabs.activeID.flatMap { views[$0]?.title }
    }

    /// Console-only font zoom (⌥⌘+ / ⌥⌘− / ⌥⌘0): adjust just the focused terminal's font via
    /// libghostty's native keybind action, independent of and layered over the global ⌘± zoom. A
    /// no-op when the active tab is the error placeholder (no live surface).
    func zoomActiveTerminalIn() { activeSurfaceView?.runBindingAction("increase_font_size:1") }
    func zoomActiveTerminalOut() { activeSurfaceView?.runBindingAction("decrease_font_size:1") }
    func resetActiveTerminalZoom() { activeSurfaceView?.runBindingAction("reset_font_size") }

    private var orderedSessions: [TerminalSession] { tabs.ids.compactMap { views[$0] } }

    // MARK: Tab lifecycle (public triggers: + button, tab clicks, native ghostty keybindings)

    /// Open a new local-shell tab and focus it (⌘T / the + button).
    func openLocalTab() {
        guard available else { return }
        add(makeLocalSession())
    }

    /// Open a console tab for a connection and focus it: an SSH connection runs `ssh …` in place of
    /// the shell; a local-folder connection starts the shell in that directory. The same builder is
    /// reused to reopen connection tabs on relaunch (`restoreTabs`).
    func openConnection(_ conn: Domain.Connection) {
        guard available, let session = makeConnectionSession(conn) else { return }
        add(session)
    }

    /// Build a (wired) session for a connection without inserting it — shared by `openConnection`
    /// and the relaunch restore. Tags the session with the connection id so it can be re-resolved.
    private func makeConnectionSession(_ conn: Domain.Connection) -> TerminalSession? {
        guard let app = ghostty.app else { return nil }
        let command: String?
        let workingDirectory: String?
        // The busy shell hook only applies to a local login shell (a folder tab), not an `ssh`
        // command — ghostty skips integration for non-shell commands anyway.
        var env: [(String, String)] = []
        switch conn.kind {
        case let .ssh(host, port, user):
            command = SSHCommand.command(host: host, port: port, user: user, custom: conn.customCommand)
            workingDirectory = nil
        case let .localFolder(path):
            command = nil
            workingDirectory = (path as NSString).expandingTildeInPath
            env = BusyShellIntegration.envVars(enabled: store.terminalBusySpinner, isLocalShell: true)
        }
        let surface = GhosttySurfaceView(app: app, command: command,
                                         workingDirectory: workingDirectory, env: env)
        return wire(TerminalSession(view: surface, title: conn.name, dot: Status.green,
                                    origin: .connection(conn.id.uuidString), lockTitle: true),
                    surface: surface)
    }

    /// Jump to another tab (native ⌘1…9 / next / previous / last).
    func gotoTab(_ jump: TabJump) {
        let before = tabs.activeID
        tabs.goto(jump)
        guard tabs.activeID != before else { return }
        refresh()
        focusActive()
        snapshotTabs()
    }

    /// Close a specific tab (its × button or a native close-tab keybinding), confirming first when
    /// a foreground process is still running.
    func requestCloseTab(id: UUID) {
        let alive = views[id]?.surfaceView?.needsConfirmQuit ?? false
        requestClose(id: id, processAlive: alive)
    }

    // MARK: Session plumbing

    private func makeLocalSession() -> TerminalSession {
        guard let app = ghostty.app else {
            return TerminalSession(view: TerminalUnavailableView(stage: .application),
                                   title: "terminal", dot: Status.red, origin: .local)
        }
        let surface = GhosttySurfaceView(
            app: app,
            env: BusyShellIntegration.envVars(enabled: store.terminalBusySpinner, isLocalShell: true))
        return wire(TerminalSession(view: surface, title: "zsh", dot: Status.green, origin: .local),
                    surface: surface)
    }

    /// Hook a surface's lifecycle/native-action callbacks back to this dock, keyed by session id.
    /// Tab mutations fire from inside ghostty_app_tick, so they're deferred off the tick before
    /// creating/freeing surfaces or spinning a modal.
    private func wire(_ session: TerminalSession, surface: GhosttySurfaceView) -> TerminalSession {
        let id = session.id
        surface.onChildExit = { [weak self] processAlive in
            DispatchQueue.main.async { self?.requestClose(id: id, processAlive: processAlive) }
        }
        surface.onTitleChange = { [weak self] title in
            self?.updateTitle(id: id, title)
        }
        surface.onNewTab = { [weak self] in
            DispatchQueue.main.async { self?.openLocalTab() }
        }
        surface.onCloseTab = { [weak self] in
            DispatchQueue.main.async { self?.requestCloseTab(id: id) }
        }
        surface.onGotoTab = { [weak self] jump in
            DispatchQueue.main.async { self?.gotoTab(jump) }
        }
        surface.onBell = { [weak self] in
            DispatchQueue.main.async { self?.bellRang(id: id) }
        }
        surface.onActivity = { [weak self] signal in
            DispatchQueue.main.async { self?.activityChanged(id: id, signal: signal) }
        }
        return session
    }

    /// A surface rang the bell / posted a notification. Flag the tab only when it's in the
    /// background and the setting is on (the active tab is already on screen — see
    /// `TerminalBellPolicy`). The `!hasBell` guard coalesces a spammy background job into a single
    /// strip repaint; `needsLayout` (not `refresh()`) keeps it to the strip — no parent relayout
    /// or window retitle.
    private func bellRang(id: UUID) {
        guard let session = views[id],
              TerminalBellPolicy.shouldFlag(isActiveTab: id == tabs.activeID,
                                            enabled: store.terminalBellBadge),
              !session.hasBell else { return }
        session.hasBell = true
        needsLayout = true
    }

    /// A surface reported an activity signal. Reduce it to a busy/idle decision via the shared
    /// `TerminalBusyPolicy` rule. Unlike the bell, busy is tracked regardless of the badge setting
    /// and on the active tab too — the `store.terminalBusySpinner` gate is applied at render time in
    /// `tabView`. The visible `busyShown` lags `isBusy` by a short debounce: with the shell hook
    /// (#94) every command flips busy, so a fast `ls` would otherwise flash a spinner. We only show
    /// it once a command has stayed busy past the delay, and hide it as soon as it finishes.
    private func activityChanged(id: UUID, signal: TerminalBusySignal) {
        let busy = TerminalBusyPolicy.isBusy(signal)
        guard let session = views[id], session.isBusy != busy else { return }
        session.isBusy = busy
        session.busyDebounce?.cancel()
        if busy {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let s = self.views[id], s.isBusy, !s.busyShown else { return }
                s.busyShown = true
                self.needsLayout = true
            }
            session.busyDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            session.busyDebounce = nil
            if session.busyShown { session.busyShown = false; needsLayout = true }
        }
    }

    /// Insert a prepared session into the model + map (no relayout, no persist); used to seed the
    /// first tab and to rebuild tabs during restore.
    private func register(_ session: TerminalSession) {
        views[session.id] = session
        tabs.open(session.id)
    }

    // MARK: Persistence (reopen tabs on relaunch)

    /// Save the open tabs (order + which is active) so they reopen next launch. Called after every
    /// tab mutation; `register` deliberately doesn't, so the launch seed never overwrites the saved
    /// set before `restoreTabs` runs.
    private func snapshotTabs() {
        guard available else { return }
        store.terminalTabs = orderedSessions.map { session in
            let id = session.id.uuidString
            switch session.origin {
            case .local: return TerminalTabState(id: id, kind: .local, title: session.title,
                                                 locked: session.lockTitle)
            case .connection(let connId): return TerminalTabState(id: id, kind: .connection(id: connId),
                                                                  title: session.title, locked: session.lockTitle)
            }
        }
        store.activeTerminalTabId = tabs.activeID.map { $0.uuidString }
        store.persist()
    }

    /// Reopen the saved tabs at launch (called once connections are loaded). Local shells are
    /// re-seeded; connection tabs are re-resolved by id and reconnected (re-running their SSH /
    /// folder command). Each tab's saved name is restored — a renamed local tab also restores its
    /// title lock so the shell can't overwrite it (#30); connection tabs stay locked (#29). The tab
    /// that was active is re-selected by its saved id, so a dropped earlier tab doesn't shift it. A
    /// tab whose connection was deleted is skipped, and an all-unresolved or never-saved set falls
    /// back to a single local shell so the dock is never empty.
    func restoreTabs(connections: [Domain.Connection]) {
        guard available else { return }
        let states = store.terminalTabs
        guard !states.isEmpty else { snapshotTabs(); return }   // nothing saved → persist the seed

        // Drop the seeded session(s) and rebuild from the saved order.
        for session in views.values { session.view.removeFromSuperview() }
        views.removeAll()
        tabs = TerminalTabs<UUID>()

        let savedActiveId = store.activeTerminalTabId
        var activeSessionId: UUID?
        for state in states {
            let session: TerminalSession?
            switch state.kind {
            case .local:
                session = makeLocalSession()
            case .connection(let id):
                session = connections.first(where: { $0.id.uuidString == id }).flatMap(makeConnectionSession)
            }
            guard let session else { continue }   // connection was deleted
            if !state.title.isEmpty { session.title = state.title }   // restore a renamed tab's name
            if case .local = state.kind { session.lockTitle = state.locked }   // connection tabs stay locked
            register(session)
            if state.id == savedActiveId { activeSessionId = session.id }
        }
        if tabs.isEmpty { register(makeLocalSession()) }   // every saved connection was deleted

        // Re-select the tab that was active; if it was dropped, fall back to the first surviving tab.
        if let activeSessionId { tabs.select(activeSessionId) }
        else if let first = tabs.ids.first { tabs.select(first) }
        refresh()
        focusActive()
        snapshotTabs()   // re-persist with fresh session ids, dropping any tabs that couldn't be resolved
    }

    private func add(_ session: TerminalSession) {
        register(session)
        refresh()
        focusActive()
        snapshotTabs()
    }

    private func updateTitle(id: UUID, _ title: String) {
        guard let session = views[id],
              let resolved = TerminalTitlePolicy.resolved(incoming: title, current: session.title,
                                                          locked: session.lockTitle) else { return }
        session.title = resolved
        needsLayout = true   // relabel the tab strip; no surface churn
        if id == tabs.activeID { onActiveTitleChange?() }   // visible tab's server title changed → retitle window
    }

    private func requestClose(id: UUID, processAlive: Bool) {
        guard views[id] != nil else { return }   // already gone
        if TerminalClosePolicy.shouldConfirmClose(processAlive: processAlive) {
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText = "A process is still running."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        closeSession(id: id)
    }

    private func closeSession(id: UUID) {
        guard let closing = views[id] else { return }
        closing.view.removeFromSuperview()   // drops the last strong ref → deinit frees the surface
        views[id] = nil
        tabs.close(id)                        // picks the next active per the tested rule

        // Never leave the dock empty (and so never let the last `exit` quit the app).
        if tabs.isEmpty, available {
            add(makeLocalSession())   // `add` snapshots
            return
        }
        refresh()
        focusActive()
        snapshotTabs()
    }

    private func selectSession(id: UUID) {
        guard tabs.activeID != id else { return }
        tabs.select(id)
        refresh()
        focusActive()
        snapshotTabs()
    }

    // MARK: Inline rename (#30)

    /// A single click selects the tab; a second click on the same tab within the system
    /// double-click interval renames it. Timed here on the container (which survives the strip
    /// rebuild) rather than via the row's `clickCount`, the same reason as `ConnectionRailView`.
    private func handleTabClick(id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastTabClickId == id, now - lastTabClickAt <= NSEvent.doubleClickInterval {
            lastTabClickId = nil
            beginRename(id: id)
        } else {
            lastTabClickId = id
            lastTabClickAt = now
            selectSession(id: id)
        }
    }

    /// Enter edit mode on a tab: rebuild the strip so `tabView` swaps that tab's label for an
    /// editable field (focused + select-all happens once it's in the view tree).
    private func beginRename(id: UUID) {
        guard views[id] != nil else { return }
        lastTabClickId = nil
        editingTabId = id
        needsLayout = true
    }

    /// Commit the edited name: lock the tab so the shell/server can't overwrite it, persist, and
    /// rebuild. Idempotent — clears edit state first, so the end-editing notification that follows
    /// the rebuild is a no-op (no double-commit between Return/Esc and focus-loss).
    private func commitRename() {
        guard let id = editingTabId, let session = views[id] else { return }
        let draft = editField?.stringValue ?? ""
        editingTabId = nil
        editField = nil
        if let title = TerminalTitlePolicy.renamed(to: draft) {
            session.title = title
            session.lockTitle = true
            snapshotTabs()
        }
        refresh()
        focusActive()
    }

    /// Abandon the edit (Esc): keep the old title, leave the lock untouched, rebuild.
    private func cancelRename() {
        guard editingTabId != nil else { return }
        editingTabId = nil
        editField = nil
        refresh()
        focusActive()
    }

    private func focusActive() {
        guard let view = activeSurfaceView else { return }
        // On the open-tab (#75) and restore paths the active surface is attached to the window only
        // inside layout() (deferred to the display cycle), so it isn't in the window yet when we focus
        // it — and makeFirstResponder on an unattached view is a no-op, leaving the window with no
        // first responder, so the first keystroke beeps ("can't type until you click"). refresh() just
        // armed needsLayout; run that pending layout now so the surface is added + sized
        // (viewDidMoveToWindow) before we make it first responder. Deferring via DispatchQueue.main.async
        // does NOT work: CFRunLoop drains the main queue before the layout/CA-commit observer, so the
        // surface still wouldn't be installed.
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(view)
        // The single choke point every focus path funnels through, so clearing the badge here
        // covers click / ⌘-number / next-prev / open / close / restore / rename (#74).
        if let id = tabs.activeID, let session = views[id], session.hasBell {
            session.hasBell = false
            needsLayout = true
        }
    }

    private func refresh() {
        needsLayout = true
        onRelayout?()
        onActiveTitleChange?()   // active tab may have changed (open/close/select/goto/restore) → retitle window
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let t = store.theme
        let w = bounds.width, h = bounds.height
        layer?.backgroundColor = t.termBg.cgColor

        // Carry the strip's horizontal scroll offset across this rebuild. Read before the cleanup
        // below removes the old bar (and its scroll view) — mirrors `RepoPanelView`'s `priorListOffset`.
        let priorTabOffset = tabScroll?.contentView.bounds.origin

        // Keep every session view; rebuild only the chrome (strip, status). The resize grip is no
        // longer a child here — it lives on the split container so it can straddle the seam (#84).
        let keep = Set(views.values.map { ObjectIdentifier($0.view) })
        subviews.filter { !keep.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        for session in views.values where session.view.superview !== self {
            addSubview(session.view)   // the tab bar is re-added every layout, so it stays above the surfaces
        }

        // The dock fills its whole frame: tab bar across the top, active surface below. The detail↔
        // terminal divider is owned and drawn by `CenterColumnView` (#84), not carved off here.
        let content = NSRect(x: 0, y: 0, width: w, height: h)

        let barH: CGFloat = z(32)
        layoutTabBar(x: content.minX, w: content.width, y: content.minY, barH: barH, priorOffset: priorTabOffset)

        // Active surface fills the rest of the content; inactive sessions stay attached but hidden (so
        // their libghostty surfaces keep their Metal layers instead of being torn down on every switch).
        let surfaceTop = content.minY + barH
        let surfaceH = max(0, content.maxY - surfaceTop)
        let activeID = tabs.activeID
        for session in views.values {
            let active = session.id == activeID
            session.view.isHidden = !active
            if active { session.view.frame = NSRect(x: content.minX, y: surfaceTop, width: content.width, height: surfaceH) }
        }
    }

    private func layoutTabBar(x: CGFloat, w: CGFloat, y: CGFloat, barH: CGFloat, priorOffset: NSPoint?) {
        let t = store.theme
        let bar = FlippedView(frame: NSRect(x: x, y: y, width: w, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = t.panel.cgColor
        let topB = BoxView(bg: t.line); topB.frame = NSRect(x: 0, y: 0, width: w, height: z(1)); bar.addSubview(topB)
        let botB = BoxView(bg: t.line2); botB.frame = NSRect(x: 0, y: barH - z(1), width: w, height: z(1)); bar.addSubview(botB)

        if available {
            // Tabs + the `+` button live in a scrolling document so they stay reachable when they
            // overflow the window width (#21). The doc is inset to clear the pinned resize chevron.
            // `AutoHideScrollView` floats its own slim indicator instead of an AppKit scroller (which
            // would reserve a band that clips each tab's bottom underline). It stays hidden at rest and
            // reveals only while scrolling, fading ~1s after. (#21 follow-up)
            let scroll = AutoHideScrollView(frame: NSRect(x: 0, y: 0, width: w - z(36), height: barH))
            scroll.drawsBackground = false
            scroll.knobColor = t.txt4
            scroll.horizontalScrollElasticity = .allowed
            scroll.verticalScrollElasticity = .none

            let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w - z(36), height: barH))
            var x: CGFloat = 0
            var activeRect: NSRect?
            tabRowsById.removeAll()   // rebuilt each layout; keyed by id for the drag reflow (#87)
            for session in orderedSessions {
                let tw = tabWidth(for: session.title)
                let row = tabView(session, width: tw, barH: barH, x: x)
                tabRowsById[session.id] = row
                doc.addSubview(row)
                if session.id == tabs.activeID { activeRect = NSRect(x: x, y: 0, width: tw, height: barH) }
                x += tw
            }
            tabDoc = doc
            // New local tab. Trailing slack keeps the `+` off the right edge of the document.
            let plus = ClickRow(bg: nil)
            plus.hoverColor = t.hover
            plus.frame = NSRect(x: x + z(4), y: z(5), width: z(22), height: barH - z(10))
            plus.onClick = { [weak self] in self?.openLocalTab() }
            let pl = label("+", sys(15), t.txt4, align: .center)
            pl.frame = plus.bounds; plus.addSubview(pl)
            doc.addSubview(plus)

            // Document height must equal the clip height exactly — a taller flipped doc anchors to the
            // top and can spawn a stray vertical scroller. Width spans the tabs + the `+` button extent.
            doc.frame = NSRect(x: 0, y: 0, width: x + z(4) + z(22) + z(4), height: barH)
            scroll.documentView = doc
            bar.addSubview(scroll)
            tabScroll = scroll

            // Restore the user's manual scroll across a plain repaint (e.g. an OSC title relabel), then
            // bring the active tab into view only when it actually changed — so manual scrolling sticks.
            if let off = priorOffset {
                let maxX = max(0, doc.frame.width - scroll.contentView.bounds.width)
                scroll.contentView.scroll(to: NSPoint(x: min(off.x, maxX), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if let active = tabs.activeID, let rect = activeRect, active != lastFocusedTabId {
                lastFocusedTabId = active
                DispatchQueue.main.async { [weak doc] in doc?.scrollToVisible(rect.insetBy(dx: -z(24), dy: 0)) }
            } else if tabs.activeID == nil {
                lastFocusedTabId = nil
            }
            // Resting state: the indicator is invisible until the user actually scrolls (the programmatic
            // scrolls above don't go through `scrollWheel`, so they leave it hidden).
            scroll.hideKnobNow()
        } else {
            let nm = label("terminal unavailable", sys(11.5), t.txt3)
            nm.frame = NSRect(x: z(14), y: z(8), width: w - z(28), height: z(16)); bar.addSubview(nm)
        }

        // Quick-snap chevron pinned at the far right, OUTSIDE the scroll view so it's never scrolled
        // off. There's no duplicate status text here anymore — each tab already carries its own title,
        // and the old right-aligned status label sat on top of the rightmost tab's × button. The glyph
        // and the snap target follow the active split axis: grow/shrink the height in a vertical split,
        // the width fraction in a horizontal one.
        let wideFraction = 0.7
        let isLarge = store.splitAxis == .vertical ? store.terminalHeight > 500 : Double(store.terminalFraction) > 0.6
        // An SF Symbol chevron, not a Unicode arrowhead: ⌃/⌄ sit at the top/bottom of their line box
        // (so ⌄ always reads low), whereas the symbol's glyph is centered in its own bounds and an
        // NSImageView then centers that in the button — the same way the titlebar icons align.
        let symbol = store.splitAxis == .vertical ? (isLarge ? "chevron.down" : "chevron.up")
                                                  : (isLarge ? "chevron.right" : "chevron.left")
        // Mirror the `+` new-tab button: a 22×(barH-10) hit target at y=5 with the same hover fill.
        let chevBtn = ClickRow(bg: nil)
        chevBtn.hoverColor = t.hover
        chevBtn.frame = NSRect(x: w - z(30), y: z(5), width: z(22), height: barH - z(10))
        let chev = NSImageView(frame: chevBtn.bounds)
        chev.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        chev.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: z(11), weight: .semibold)
        chev.contentTintColor = t.txt3
        chev.imageScaling = .scaleNone            // render at the configured size, centered in the button
        chevBtn.addSubview(chev)
        chevBtn.onClick = { [weak self] in
            guard let self else { return }
            switch self.store.splitAxis {
            case .vertical:
                self.store.terminalHeight = self.store.terminalHeight > 500 ? 240 : 700
            case .horizontal:
                self.store.terminalFraction = Double(self.store.terminalFraction) > 0.6
                    ? CGFloat(Domain.SplitLayout.defaultFraction) : CGFloat(wideFraction)
            }
            self.onRelayout?()
            self.store.persist()
        }
        bar.addSubview(chevBtn)
        addSubview(bar)
    }

    private func tabWidth(for title: String) -> CGFloat {
        // Glyph dot + label + close button, clamped so long titles (ssh hosts) don't dominate.
        min(z(200), max(z(86), fitW(title, sys(11.5, .semibold)) + z(56)))
    }

    private func tabView(_ session: TerminalSession, width tw: CGFloat, barH: CGFloat, x: CGFloat) -> ClickRow {
        let t = store.theme
        let active = session.id == tabs.activeID
        // The active tab reads as a continuation of the surface below it, so it shares the terminal bg.
        let tab = ClickRow(bg: active ? t.termBg : nil)
        tab.hoverColor = active ? nil : t.hover
        tab.frame = NSRect(x: x, y: 0, width: tw, height: barH)
        // Click/rename is routed through the drag grip below (so a press can become a drag); the
        // bare `ClickRow` keeps only its hover fill.

        // A background tab that rang/notified reads as "wants attention": amber underline + dot,
        // mirroring the active tab's green underline (#74). The active tab never flags.
        let flagged = session.hasBell && !active
        let underline = BoxView(bg: active ? Status.green : (flagged ? Status.yellow : .clear))
        underline.frame = NSRect(x: 0, y: barH - z(2), width: tw, height: z(2)); tab.addSubview(underline)
        // A busy surface swaps the status dot for a spinner while the user has the setting on (#93).
        // The spinner is centered on the dot's slot and self-stops when the next strip rebuild
        // removes it (see `makeSpinner`); `isBusy` is independent of `flagged`, so a busy tab spins
        // even if it also rang the bell. Without the swap, the existing amber/normal dot is drawn.
        if store.terminalBusySpinner && session.busyShown {
            let spinner = makeSpinner(size: z(14))
            spinner.frame.origin = NSPoint(x: z(13) + (z(7) - z(14)) / 2, y: (barH - z(14)) / 2)
            tab.addSubview(spinner)
        } else {
            let d = Dot(flagged ? Status.yellow : session.dot, z(7)); d.frame.origin = NSPoint(x: z(13), y: (barH - z(7)) / 2); tab.addSubview(d)
        }
        let nameFrame = NSRect(x: z(28), y: z(8), width: tw - z(28) - z(24), height: z(16))
        if session.id == editingTabId {
            tab.addSubview(renameEditor(session.title, frame: nameFrame, t: t))
        } else {
            let nm = label(session.title, sys(11.5, active ? .semibold : .regular), active ? t.txt : t.txt3)
            nm.frame = nameFrame; tab.addSubview(nm)
        }

        // Whole-tab drag handle (#87): a press becomes a reorder past the threshold, else a plain
        // select/rename click. Added over the label/dot but *under* the close × (added next), so
        // close stays clickable; skipped while renaming so the inline editor keeps the clicks.
        if session.id != editingTabId {
            let grip = DragGrip(frame: tab.bounds)
            grip.onDown = { [weak self] e in self?.tabMouseDown(id: session.id, event: e) }
            grip.onDrag = { [weak self] e in self?.tabMouseDragged(event: e) }
            grip.onUp = { [weak self] _ in self?.tabMouseUp(id: session.id) }
            tab.addSubview(grip)
        }

        // Per-tab close (×). Sits above the tab, so its click closes without also selecting.
        let close = ClickRow(radius: z(4))
        close.hoverColor = t.hover
        close.frame = NSRect(x: tw - z(22), y: (barH - z(18)) / 2, width: z(18), height: z(18))
        close.onClick = { [weak self] in self?.requestCloseTab(id: session.id) }
        let xl = label("×", sys(13), t.txt3, align: .center)
        xl.frame = close.bounds; close.addSubview(xl)
        tab.addSubview(close)

        let sep = BoxView(bg: t.line); sep.frame = NSRect(x: tw - z(1), y: 0, width: z(1), height: barH); tab.addSubview(sep)
        return tab
    }

    // MARK: Drag — reorder tabs by dragging (#87)

    /// The whole tab is a drag handle (browser/Terminal.app style). A press records the start; a
    /// drag past the threshold begins the gesture; a release without a drag is a plain
    /// select/rename click. Mirrors `ConnectionRailView`'s row drag (#79), adapted from a vertical
    /// fixed-height list to this horizontal, variable-width strip.
    private func tabMouseDown(id: UUID, event: NSEvent) {
        tabDownId = id
        tabDownPoint = event.locationInWindow
        tabDragging = false
    }

    private func tabMouseDragged(event: NSEvent) {
        guard tabDownId != nil else { return }
        if !tabDragging {
            let moved = max(abs(event.locationInWindow.x - tabDownPoint.x),
                            abs(event.locationInWindow.y - tabDownPoint.y))
            guard moved >= tabDragThreshold else { return }
            tabDragging = true
            beginTabDrag(event: event)
        }
        updateTabDrag(event: event)
    }

    private func tabMouseUp(id: UUID) {
        if tabDragging { endTabDrag() } else { handleTabClick(id: id) }
        tabDownId = nil
        tabDragging = false
    }

    /// A tab's rendered width is a pure function of its title, so it's stable across a drag.
    private func tabWidth(forId id: UUID) -> CGFloat { tabWidth(for: views[id]?.title ?? "") }

    private func beginTabDrag(event: NSEvent) {
        guard let id = tabDownId, let doc = tabDoc, let row = tabRowsById[id] else { return }
        draggingTabId = id
        dragTabOrder = tabs.ids
        let p = doc.convert(event.locationInWindow, from: nil)
        dragTabGrabDX = p.x - row.frame.origin.x
        doc.addSubview(row)                 // raise above siblings for the shadow
        row.layer?.shadowColor = NSColor.black.cgColor
        row.layer?.shadowOpacity = 0.35
        row.layer?.shadowRadius = z(8)
        row.layer?.shadowOffset = CGSize(width: 0, height: z(2))
        row.layer?.masksToBounds = false
        row.setBase(store.theme.card)       // show the tab as "picked up"
    }

    private func updateTabDrag(event: NSEvent) {
        guard let id = draggingTabId, let doc = tabDoc, let row = tabRowsById[id] else { return }
        let p = doc.convert(event.locationInWindow, from: nil)
        let dw = tabWidth(forId: id)
        let total = dragTabOrder.reduce(CGFloat(0)) { $0 + tabWidth(forId: $1) }
        // The dragged tab follows the cursor, clamped to the strip's span.
        let newX = max(0, min(total - dw, p.x - dragTabGrabDX))
        row.frame.origin.x = newX
        // Drop index = how many *other* tabs have their midpoint left of the dragged tab's centre.
        // Walking cumulative widths (not dividing by a fixed slot) is what handles variable widths.
        let center = newX + dw / 2
        var acc: CGFloat = 0
        var target = 0
        for tid in dragTabOrder where tid != id {
            let w = tabWidth(forId: tid)
            if center > acc + w / 2 { target += 1 }
            acc += w
        }
        if let cur = dragTabOrder.firstIndex(of: id), cur != target {
            dragTabOrder.remove(at: cur)
            dragTabOrder.insert(id, at: target)
        }
        // Reflow the other tabs into their slots, reserving (skipping over) the dragged tab's gap.
        var ax: CGFloat = 0
        for tid in dragTabOrder {
            if tid != id { tabRowsById[tid]?.frame.origin.x = ax }
            ax += tabWidth(forId: tid)
        }
    }

    private func endTabDrag() {
        guard let id = draggingTabId else { return }
        draggingTabId = nil
        // `from` is the tab's index before the drag (tabs.ids is untouched until we commit); `to`
        // is where it landed in the live order. A real move commits via the Domain rule; otherwise
        // a rebuild settles the lifted row back into place.
        if let from = tabs.ids.firstIndex(of: id),
           let to = dragTabOrder.firstIndex(of: id), from != to {
            commitTabReorder(from: from, to: to)
        } else {
            refresh()
        }
    }

    /// Commit a drag-reorder: apply the tested Domain rule, rebuild the strip from the new order,
    /// and persist so it survives relaunch. The active tab (and its mounted surface) is untouched.
    private func commitTabReorder(from: Int, to: Int) {
        tabs.reorder(from: from, to: to)
        refresh()
        snapshotTabs()
    }

    /// The editable field shown in place of a tab's label while it's being renamed (#30). Borderless
    /// and on the terminal bg so it reads like the active label it replaces; styled like that label
    /// (semibold, primary text). Focus + select-all is deferred to the next runloop turn, once the
    /// field is in the view tree (the strip is built mid-`layout`).
    private func renameEditor(_ value: String, frame: NSRect, t: Theme) -> NSTextField {
        let tf = NSTextField(string: value)
        tf.font = sys(11.5, .semibold)
        tf.textColor = t.txt
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = true
        tf.backgroundColor = t.termBg
        tf.focusRingType = .none
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.isScrollable = true
        tf.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
        tf.delegate = self
        tf.frame = frame
        editField = tf
        DispatchQueue.main.async { [weak tf] in
            guard let tf, let window = tf.window else { return }
            window.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }
        return tf
    }
}

extension TerminalContainerView: NSTextFieldDelegate {
    /// Return commits the rename, Esc abandons it. Returning `true` consumes the key so AppKit
    /// doesn't also beep or insert a newline into the (now-gone) editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === editField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRename()
            return true
        default:
            return false
        }
    }

    /// Clicking away (focus loss) commits whatever was typed. Guarded by `editingTabId` so the
    /// strip rebuild that follows a Return/Esc commit — which also ends editing — doesn't re-fire.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard editingTabId != nil, (obj.object as? NSTextField) === editField else { return }
        commitRename()
    }
}
