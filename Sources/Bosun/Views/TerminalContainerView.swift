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
    /// Ephemeral busy state: what the surface last reported (#93/#94). `.indeterminate` (an OSC 9;4
    /// progress report with no percentage, or our shell hook on a plain command) draws a spinner;
    /// `.determinate(percent)` draws a progress ring; `.idle` the normal dot. Drives the dot swap in
    /// `tabView` when `store.terminalBusySpinner` is on. Live state, *not* cleared on focus (unlike
    /// `hasBell`) and not persisted.
    var busy: TerminalBusyState = .idle
    /// Whether the *indeterminate* spinner is actually drawn. Lags `busy` by a short debounce so a
    /// fast command (e.g. `ls`) that flips busy for a few ms via the shell hook (#94) doesn't
    /// flicker the tab; `busyDebounce` is the pending "show" work item, cancelled if the command
    /// finishes first. A determinate ring ignores this — an explicit percentage shows immediately.
    var busyShown = false
    var busyDebounce: DispatchWorkItem?
    /// Last-resort backstop (#94): force-clears `busy` if a tab latches a progress report then goes
    /// silent without a REMOVE / command-finish (e.g. an `ssh` tool that dies mid-report, where our
    /// shell hook isn't installed). Re-armed on every signal, so an actively-reporting tab never
    /// fires it; cancelled when the tab goes idle.
    var busyTimeout: DispatchWorkItem?

    init(view: NSView, title: String, dot: NSColor, origin: TabOrigin, lockTitle: Bool = false) {
        self.view = view
        self.title = title
        self.dot = dot
        self.origin = origin
        self.lockTitle = lockTitle
    }

    var surfaceView: GhosttySurfaceView? { view as? GhosttySurfaceView }
}

/// A resize grip between two panes of a split (#68): a `DragHandle` that also carries the split
/// node's `path` and along-axis `extent`, so the container's drag closures (set once) can turn the
/// gesture into a `SplitNode.setFraction` on the right node. Reuses `DragHandle`'s modal-loop drag,
/// which survives the mid-gesture relayout that re-positions this same handle each frame.
final class PaneDividerHandle: DragHandle {
    var path: [Int] = []
    var extent: Double = 1
}

/// A click-through overlay that outlines the focused pane when a tab is split (#68). `hitTest`
/// returns nil so it never steals clicks from the surface it sits over; the border is drawn on its
/// own layer (not the pane's `CAMetalLayer`, which a layer border would fight).
final class PaneFocusRingView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Terminal dock: live tab strip + the active tab's panes. A tab is a recursive `SplitNode` tree of
/// live libghostty surfaces (#68); order and active *tab* selection are delegated to the pure
/// `TerminalTabs` model (unit-tested in Domain), the per-tab pane layout/navigation to the pure
/// `SplitNode` (also in Domain). This view owns the pane(surface)→session map, the tab→tree map, and
/// the AppKit chrome (strip, dividers, focus ring). The detail↔terminal resize grip is a *separate*
/// split owned by `CenterColumnView` (#84). Closing the last pane of the last tab opens a fresh local
/// one so the dock is never empty and `exit` never quits the app.
final class TerminalContainerView: FlippedView {
    let store: Store
    private let ghostty: GhosttyApp
    private let available: Bool

    /// Tab ordering + which *tab* is active — the tested rule lives in Domain. `tabs.ids` are tab ids,
    /// distinct from pane (surface) ids since #68 (one tab holds a tree of panes).
    private var tabs = TerminalTabs<UUID>()
    /// pane (surface) id → session (the surface view + label). One entry per pane across *all* tabs.
    private var views: [UUID: TerminalSession] = [:]
    /// tab id → its pane split layout; leaves are pane ids in `views`. The pure tree lives in Domain.
    private var trees: [UUID: SplitNode<UUID>] = [:]
    /// tab id → the focused pane id within that tab (drives the focus ring, the window title, and
    /// which pane a split / pane-zoom targets).
    private var focusedPane: [UUID: UUID] = [:]
    /// pane id → its owning tab id (the reverse of the trees' leaves), for routing per-surface
    /// callbacks (bell/title/close/focus) back to the right tab.
    private var paneToTab: [UUID: UUID] = [:]

    /// Resize grips for the active tab's split dividers, pooled by divider path so the one being
    /// dragged persists across the per-frame relayout. The single-overlay focus ring is reused too.
    private var dividerHandles: [String: PaneDividerHandle] = [:]
    private let focusRing = PaneFocusRingView()

    /// Live divider-drag state (one gesture at a time), captured on `onBegin` and held for the whole
    /// gesture so the direction can't flip mid-drag (#65, applied per pane node).
    private var dragTabId: UUID?
    private var dragPath: [Int] = []
    private var dragStartFraction: Double = 0.5
    private var dragExtent: Double = 1
    private var dragSign: Double = 1
    private var dragFloor: Double = SplitLayout.minPane

    /// True while `restoreTabs` rebuilds the dock, so the focus/relayout it does mid-rebuild doesn't
    /// persist a half-built snapshot — restore re-persists once at the end.
    private var isRestoring = false

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
        focusRing.wantsLayer = true
        focusRing.layer?.backgroundColor = NSColor.clear.cgColor
        focusRing.isHidden = true

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

    /// The focused pane of the active tab — what keystrokes, the console zoom, and a split target.
    var activeSurfaceView: GhosttySurfaceView? {
        focusedPaneId.flatMap { views[$0]?.surfaceView }
    }

    /// The active tab's current label (its focused pane's title), for the macOS window title (#73).
    var activeTabTitle: String? {
        focusedPaneId.flatMap { views[$0]?.title }
    }

    /// The focused pane id of the active tab, falling back to the tree's first leaf.
    private var focusedPaneId: UUID? {
        guard let tab = tabs.activeID else { return nil }
        return focusedPane[tab] ?? trees[tab]?.firstLeaf
    }

    /// The representative session shown for a tab in the strip (title/dot): its focused pane.
    private func representativeSession(_ tabId: UUID) -> TerminalSession? {
        guard let pane = focusedPane[tabId] ?? trees[tabId]?.firstLeaf else { return nil }
        return views[pane]
    }

    /// Console-only font zoom (⌥⌘+ / ⌥⌘− / ⌥⌘0): adjust just the focused terminal's font via
    /// libghostty's native keybind action, independent of and layered over the global ⌘± zoom. A
    /// no-op when the active tab is the error placeholder (no live surface).
    func zoomActiveTerminalIn() { activeSurfaceView?.runBindingAction("increase_font_size:1") }
    func zoomActiveTerminalOut() { activeSurfaceView?.runBindingAction("decrease_font_size:1") }
    func resetActiveTerminalZoom() { activeSurfaceView?.runBindingAction("reset_font_size") }

    // MARK: Pane splits (#68)

    /// Split the focused pane of the active tab into two, with a fresh local shell as the new pane,
    /// and focus it. `.horizontal` lays them side by side (⌘D / Split Right), `.vertical` stacks them
    /// (⇧⌘D / Split Down). A no-op when libghostty is down.
    func splitFocusedPane(_ axis: SplitAxis) {
        guard available, let tabId = tabs.activeID, let tree = trees[tabId],
              let focused = focusedPane[tabId] ?? trees[tabId]?.firstLeaf else { return }
        let session = makeLocalSession()
        guard session.surfaceView != nil else { return }   // libghostty down → no live surface
        views[session.id] = session
        paneToTab[session.id] = tabId
        trees[tabId] = tree.insertSplit(focused: focused, axis: axis, newLeaf: session.id, newLeafTrailing: true)
        focusedPane[tabId] = session.id
        refresh()
        focusPane(session.id)
        snapshotTabs()
    }

    /// Move focus to the next/previous pane of the active tab (⌘] / ⌘[), cycling and wrapping.
    func focusNeighborPane(_ direction: PaneFocusDirection) {
        guard let tabId = tabs.activeID, let tree = trees[tabId],
              let focused = focusedPane[tabId], let neighbor = tree.focusNeighbor(of: focused, direction) else { return }
        focusedPane[tabId] = neighbor
        refresh()
        focusPane(neighbor)
        snapshotTabs()
    }

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
            DispatchQueue.main.async { self?.requestClosePane(id: id, processAlive: processAlive) }
        }
        surface.onTitleChange = { [weak self] title in
            self?.updateTitle(id: id, title)
        }
        surface.onNewTab = { [weak self] in
            DispatchQueue.main.async { self?.openLocalTab() }
        }
        surface.onCloseTab = { [weak self] in
            // ghostty's close-tab keybind (⌘W) acts on the focused *pane*: close it, and only when
            // it's the tab's last pane does the tab itself close (#68).
            DispatchQueue.main.async { self?.requestClosePane(id: id, processAlive: surface.needsConfirmQuit) }
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
        surface.onFocus = { [weak self] in
            self?.paneFocused(id: id)
        }
        return session
    }

    /// A surface rang the bell / posted a notification. Flag the tab only when it's in the
    /// background and the setting is on (the active tab is already on screen — see
    /// `TerminalBellPolicy`). The `!hasBell` guard coalesces a spammy background job into a single
    /// strip repaint; `needsLayout` (not `refresh()`) keeps it to the strip — no parent relayout
    /// or window retitle.
    private func bellRang(id: UUID) {
        guard let session = views[id], let tabId = paneToTab[id],
              TerminalBellPolicy.shouldFlag(isActiveTab: tabId == tabs.activeID,
                                            enabled: store.terminalBellBadge),
              !session.hasBell else { return }
        session.hasBell = true
        needsLayout = true
    }

    /// A pane became first responder (a click, or `focusPane`). Record it as its tab's focused pane,
    /// move the ring / window title when it's the active tab, and persist the new focus. The single
    /// choke point for "this pane has focus", reached via `GhosttySurfaceView.onFocus` (#68).
    private func paneFocused(id: UUID) {
        guard let tabId = paneToTab[id] else { return }
        let changed = focusedPane[tabId] != id
        focusedPane[tabId] = id
        guard tabId == tabs.activeID else { return }
        clearBells(inTab: tabId)
        if changed {
            needsLayout = true            // move the focus ring + relabel the strip's representative
            onActiveTitleChange?()        // the focused pane is the window/title-bar label
            if !isRestoring { snapshotTabs() }
        }
    }

    /// Clear the activity badge on every pane of a tab — the tab is now foreground, so the attention
    /// it asked for is satisfied (#74). Returns whether anything changed.
    @discardableResult
    private func clearBells(inTab tabId: UUID) -> Bool {
        var changed = false
        for paneId in trees[tabId]?.leafIDs ?? [] where views[paneId]?.hasBell == true {
            views[paneId]?.hasBell = false
            changed = true
        }
        if changed { needsLayout = true }
        return changed
    }

    /// How long a tab may stay busy with no further signal before the backstop force-clears it (#94).
    /// Far longer than any interactive command and re-armed on every signal, so it only ever fires
    /// for a genuinely abandoned indicator (a tool that latches busy then goes silent — typically an
    /// `ssh` tab, where our shell hook isn't installed to emit the REMOVE).
    private static let busyBackstop: TimeInterval = 600

    /// A surface reported an activity signal. Reduce it to a busy state via the shared
    /// `TerminalBusyPolicy` rule. Unlike the bell, busy is tracked regardless of the badge setting
    /// and on the active tab too — the `store.terminalBusySpinner` gate is applied at render time in
    /// `tabView`. An *indeterminate* spinner lags `busy` by a short debounce: with the shell hook
    /// (#94) every command flips busy, so a fast `ls` would otherwise flash a spinner; we only show
    /// it once a command has stayed busy past the delay. A *determinate* ring shows immediately — an
    /// explicit percentage is a meaningful report, not the flicker the debounce exists to swallow.
    private func activityChanged(id: UUID, signal: TerminalBusySignal) {
        guard let session = views[id] else { return }
        let new = TerminalBusyPolicy.state(signal)
        rearmBusyTimeout(session, id: id, state: new)
        guard session.busy != new else { return }

        // Whether an indicator was actually on screen before this change — a still-debouncing
        // indeterminate isn't, so flipping it straight to idle (the fast-`ls` case) repaints nothing.
        let wasVisible: Bool
        switch session.busy {
        case .determinate: wasVisible = true
        case .indeterminate: wasVisible = session.busyShown
        case .idle: wasVisible = false
        }

        session.busy = new
        session.busyDebounce?.cancel(); session.busyDebounce = nil
        session.busyShown = false

        switch new {
        case .determinate:
            needsLayout = true                       // explicit percentage → show / update at once
        case .indeterminate:
            let work = DispatchWorkItem { [weak self] in
                guard let self, let s = self.views[id], s.busy == .indeterminate, !s.busyShown else { return }
                s.busyShown = true
                self.needsLayout = true
            }
            session.busyDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            if wasVisible { needsLayout = true }     // drop a prior ring now while the spinner debounces
        case .idle:
            if wasVisible { needsLayout = true }     // relayout only if something was on screen
        }
    }

    /// Re-arm (or, when idle, cancel) the stuck-indicator backstop for a session. Called on every
    /// signal — including identical re-pings — so an actively-reporting tab keeps pushing its
    /// deadline out and never trips it; only a tab that goes silent while still busy is force-cleared.
    private func rearmBusyTimeout(_ session: TerminalSession, id: UUID, state: TerminalBusyState) {
        session.busyTimeout?.cancel(); session.busyTimeout = nil
        guard state != .idle else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let s = self.views[id], s.busy != .idle else { return }
            self.activityChanged(id: id, signal: .progress(.remove))   // force-clear via the idle path
        }
        session.busyTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyBackstop, execute: work)
    }

    /// Insert a prepared session as a brand-new single-pane tab (no relayout, no persist); used to
    /// seed the first tab, to open a new tab, and for the never-empty-dock fallback.
    private func register(_ session: TerminalSession) {
        let tabId = UUID()
        views[session.id] = session
        paneToTab[session.id] = tabId
        trees[tabId] = .leaf(session.id)
        focusedPane[tabId] = session.id
        tabs.open(tabId)
    }

    // MARK: Persistence (reopen tabs on relaunch)

    /// Save the open tabs (order + which is active) so they reopen next launch. Called after every
    /// tab mutation; `register` deliberately doesn't, so the launch seed never overwrites the saved
    /// set before `restoreTabs` runs.
    private func snapshotTabs() {
        guard available, !isRestoring else { return }
        var treeStates: [SplitNode<TerminalTabState>] = []
        var representatives: [TerminalTabState] = []
        for tabId in tabs.ids {
            guard let tree = trees[tabId] else { continue }
            treeStates.append(tree.mapLeaves { paneId in self.tabState(forPane: paneId) })
            // One representative (focused) leaf per tab so an older build still reopens the tabs.
            let repPane = focusedPane[tabId] ?? tree.firstLeaf
            representatives.append(tabState(forPane: repPane))
        }
        store.terminalTabTrees = treeStates
        store.terminalTabs = representatives
        // The active pane (and so the active tab) keyed by its leaf id.
        store.activeTerminalTabId = tabs.activeID.flatMap { focusedPane[$0]?.uuidString }
        store.persist()
    }

    /// The persisted shape of one pane (`TerminalTabState`) — local vs. connection, its title + lock.
    private func tabState(forPane paneId: UUID) -> TerminalTabState {
        let session = views[paneId]
        let id = paneId.uuidString
        switch session?.origin ?? .local {
        case .local:
            return TerminalTabState(id: id, kind: .local, title: session?.title ?? "", locked: session?.lockTitle ?? false)
        case .connection(let connId):
            return TerminalTabState(id: id, kind: .connection(id: connId),
                                    title: session?.title ?? "", locked: session?.lockTitle ?? false)
        }
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
        // Prefer the per-tab pane trees (#68); fall back to the legacy flat list (one un-split tab
        // per entry) from a pre-#68 build. Nothing saved → persist the seed.
        let savedTrees = store.terminalTabTrees
        let savedFlat = store.terminalTabs
        guard !savedTrees.isEmpty || !savedFlat.isEmpty else { snapshotTabs(); return }
        let persisted = savedTrees.isEmpty ? savedFlat.map { SplitNode.leaf($0) } : savedTrees

        isRestoring = true

        // Drop the seeded session(s) and rebuild from the saved layout.
        for session in views.values { session.view.removeFromSuperview() }
        views.removeAll(); paneToTab.removeAll(); trees.removeAll(); focusedPane.removeAll()
        tabs = TerminalTabs<UUID>()

        let savedActiveId = store.activeTerminalTabId
        var activeTab: UUID?
        let connById = Dictionary(connections.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

        for stateTree in persisted {
            let tabId = UUID()
            var activePane: UUID?
            // Rebuild a live session per leaf; a leaf whose connection was deleted maps to nil and is
            // pruned by `compacted`, collapsing its sibling up (#68).
            let liveTree = stateTree.mapLeaves { state -> UUID? in
                let session: TerminalSession?
                switch state.kind {
                case .local: session = makeLocalSession()
                case .connection(let id): session = connById[id].flatMap(makeConnectionSession)
                }
                guard let session else { return nil }   // connection was deleted
                if !state.title.isEmpty { session.title = state.title }
                if case .local = state.kind { session.lockTitle = state.locked }   // connection tabs stay locked
                views[session.id] = session
                paneToTab[session.id] = tabId
                if state.id == savedActiveId { activePane = session.id }
                return session.id
            }.compacted()
            guard let liveTree else { continue }   // every pane's connection was deleted
            trees[tabId] = liveTree
            let focus = activePane.flatMap { liveTree.contains($0) ? $0 : nil } ?? liveTree.firstLeaf
            focusedPane[tabId] = focus
            tabs.open(tabId)
            if activePane != nil { activeTab = tabId }
        }
        if tabs.isEmpty { register(makeLocalSession()) }   // every saved connection was deleted

        // Re-select the tab that was active; if it was dropped, fall back to the first surviving tab.
        if let activeTab { tabs.select(activeTab) }
        else if let first = tabs.ids.first { tabs.select(first) }
        isRestoring = false
        refresh()
        focusActive()
        snapshotTabs()   // re-persist with fresh session ids, dropping any panes that couldn't be resolved
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
        // Only the active tab's *focused* pane drives the window/title-bar label.
        if let tabId = paneToTab[id], tabId == tabs.activeID, focusedPane[tabId] == id { onActiveTitleChange?() }
    }

    // MARK: Closing panes / tabs (#68)

    /// Close one pane (its ghostty ⌘W, or a shell exit). When it's the tab's last pane, the tab
    /// closes too. Confirms first when the pane's process is still running.
    private func requestClosePane(id paneId: UUID, processAlive: Bool) {
        guard views[paneId] != nil else { return }   // already gone
        if TerminalClosePolicy.shouldConfirmClose(processAlive: processAlive),
           !confirmClose(message: "Close this terminal?") { return }
        closePane(id: paneId)
    }

    /// Close a whole tab (its × button). Confirms when *any* of its panes has a running process.
    func requestCloseTab(id tabId: UUID) {
        guard trees[tabId] != nil else { return }
        let alive = (trees[tabId]?.leafIDs ?? []).contains { views[$0]?.surfaceView?.needsConfirmQuit == true }
        if TerminalClosePolicy.shouldConfirmClose(processAlive: alive),
           !confirmClose(message: "Close this terminal tab?") { return }
        closeTab(tabId)
    }

    private func confirmClose(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "A process is still running."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func freePane(_ paneId: UUID) {
        views[paneId]?.view.removeFromSuperview()   // drops the last strong ref → deinit frees the surface
        views[paneId] = nil
        paneToTab[paneId] = nil
    }

    private func closePane(id paneId: UUID) {
        guard let tabId = paneToTab[paneId], let tree = trees[tabId] else { return }
        let wasFocused = (focusedPane[tabId] ?? tree.firstLeaf) == paneId
        let neighbor = tree.focusNeighbor(of: paneId, .next)   // a survivor, or nil if it was the only pane
        freePane(paneId)
        guard let newTree = tree.remove(paneId) else { finishCloseTab(tabId); return }   // last pane → close tab
        trees[tabId] = newTree
        let focus = wasFocused ? (neighbor ?? newTree.firstLeaf) : (focusedPane[tabId] ?? newTree.firstLeaf)
        focusedPane[tabId] = focus
        refresh()
        focusPane(focus)
        snapshotTabs()
    }

    private func closeTab(_ tabId: UUID) {
        for paneId in trees[tabId]?.leafIDs ?? [] { freePane(paneId) }
        finishCloseTab(tabId)
    }

    /// Drop a tab's remaining state and re-activate/refresh. Never leaves the dock empty (so the last
    /// `exit` never quits the app).
    private func finishCloseTab(_ tabId: UUID) {
        trees[tabId] = nil
        focusedPane[tabId] = nil
        tabs.close(tabId)   // picks the next active per the tested rule
        if tabs.isEmpty, available {
            add(makeLocalSession())   // `add` snapshots
            return
        }
        refresh()
        focusActive()
        snapshotTabs()
    }

    private func selectTab(_ tabId: UUID) {
        guard tabs.activeID != tabId else { return }
        tabs.select(tabId)
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
            selectTab(id)
        }
    }

    /// Enter edit mode on a tab: rebuild the strip so `tabView` swaps that tab's label for an
    /// editable field (focused + select-all happens once it's in the view tree).
    private func beginRename(id tabId: UUID) {
        guard representativeSession(tabId) != nil else { return }
        lastTabClickId = nil
        editingTabId = tabId
        needsLayout = true
    }

    /// Commit the edited name: lock the tab so the shell/server can't overwrite it, persist, and
    /// rebuild. Idempotent — clears edit state first, so the end-editing notification that follows
    /// the rebuild is a no-op (no double-commit between Return/Esc and focus-loss).
    private func commitRename() {
        guard let id = editingTabId, let session = representativeSession(id) else { return }
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

    /// Focus the active tab's focused pane (the common path for open/close/select/goto/restore/rename).
    private func focusActive() {
        guard let pane = focusedPaneId else { return }
        focusPane(pane)
    }

    /// Make `paneId`'s surface first responder, recording it as its tab's focused pane and clearing
    /// the tab's activity badge (#74). Used for both the active-tab focus paths and the split / focus-
    /// move actions (#68).
    private func focusPane(_ paneId: UUID) {
        guard let view = views[paneId]?.surfaceView else { return }
        if let tabId = paneToTab[paneId] { focusedPane[tabId] = paneId }
        // On the open-tab (#75), split, and restore paths the surface is attached to the window only
        // inside layout() (deferred to the display cycle), so it isn't in the window yet when we focus
        // it — and makeFirstResponder on an unattached view is a no-op, leaving the window with no
        // first responder, so the first keystroke beeps ("can't type until you click"). refresh() just
        // armed needsLayout; run that pending layout now so the surface is added + sized
        // (viewDidMoveToWindow) before we make it first responder. Deferring via DispatchQueue.main.async
        // does NOT work: CFRunLoop drains the main queue before the layout/CA-commit observer, so the
        // surface still wouldn't be installed.
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(view)
        // The single choke point every focus path funnels through, so clearing the tab's badge here
        // covers click / ⌘-number / next-prev / open / close / restore / rename / split (#74).
        if let tabId = paneToTab[paneId] { clearBells(inTab: tabId) }
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

        // Keep every pane surface (and the pooled divider grips + focus ring); rebuild only the chrome
        // (strip, status). The detail↔terminal resize grip lives on the split container (#84); the
        // in-tab pane dividers are managed separately in `layoutPanes`.
        var keep = Set(views.values.map { ObjectIdentifier($0.view) })
        keep.insert(ObjectIdentifier(focusRing))
        for handle in dividerHandles.values { keep.insert(ObjectIdentifier(handle)) }
        subviews.filter { !keep.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        for session in views.values where session.view.superview !== self {
            addSubview(session.view)   // the tab bar is re-added every layout, so it stays above the surfaces
        }

        // The dock fills its whole frame: tab bar across the top, the active tab's pane tree below. The
        // detail↔terminal divider is owned and drawn by `CenterColumnView` (#84), not carved off here.
        let content = NSRect(x: 0, y: 0, width: w, height: h)
        let barH: CGFloat = z(32)
        let paneArea = NSRect(x: 0, y: content.minY + barH, width: w, height: max(0, content.maxY - content.minY - barH))
        layoutPanes(in: paneArea)
        layoutTabBar(x: content.minX, w: content.width, y: content.minY, barH: barH, priorOffset: priorTabOffset)
    }

    /// Lay out the active tab's panes within `area` from its `SplitNode` tree, host one resize grip
    /// per divider, and outline the focused pane. Every other tab's panes are hidden in place so their
    /// libghostty Metal layers survive the switch (#68).
    private func layoutPanes(in area: NSRect) {
        let activeTab = tabs.activeID
        for (paneId, session) in views where paneToTab[paneId] != activeTab { session.view.isHidden = true }

        guard let activeTab, let tree = trees[activeTab] else { focusRing.isHidden = true; return }
        let rect = SplitRect(minX: Double(area.minX), minY: Double(area.minY),
                             width: Double(area.width), height: Double(area.height))
        let gap = Double(z(6))
        // Dim the unfocused panes of a split tab (Ghostty's `unfocused-split-opacity`), unless turned
        // off or the tab has a single pane (then everything is at full opacity).
        let multiPane = tree.leafCount > 1
        let focused = focusedPane[activeTab] ?? tree.firstLeaf
        let dim = multiPane && store.terminalDimUnfocused

        var framesByPane: [UUID: NSRect] = [:]
        for (paneId, frame) in tree.frames(in: rect, divider: gap) {
            guard let session = views[paneId] else { continue }
            let rect = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            session.view.isHidden = false
            session.view.frame = rect
            session.view.alphaValue = (dim && paneId != focused) ? Self.unfocusedPaneOpacity : 1.0
            framesByPane[paneId] = rect
        }

        layoutDividers(tree.dividers(in: rect, divider: gap))
        layoutFocusRing(tabId: activeTab, multiPane: multiPane, framesByPane: framesByPane)
    }

    /// The opacity of an unfocused pane when dimming is on — Ghostty's `unfocused-split-opacity`
    /// default (#68).
    private static let unfocusedPaneOpacity: CGFloat = 0.7

    /// Pool one `PaneDividerHandle` per divider (keyed by path so the dragged one persists across the
    /// per-frame relayout), position its fat seam-centered hit-zone, and draw the thin visible seam.
    private func layoutDividers(_ dividers: [SplitDivider]) {
        let t = store.theme
        let hit = z(12)
        var live = Set<String>()
        for divider in dividers {
            let key = pathKey(divider.path)
            live.insert(key)
            let handle = dividerHandles[key] ?? {
                let new = PaneDividerHandle(); configureDividerHandle(new); dividerHandles[key] = new; return new
            }()
            handle.path = divider.path
            handle.extent = divider.extent
            handle.axis = divider.axis
            let seam = divider.rect
            switch divider.axis {
            case .horizontal:
                let cx = CGFloat(seam.minX + seam.width / 2)
                handle.frame = NSRect(x: cx - hit / 2, y: CGFloat(seam.minY), width: hit, height: CGFloat(seam.height))
            case .vertical:
                let cy = CGFloat(seam.minY + seam.height / 2)
                handle.frame = NSRect(x: CGFloat(seam.minX), y: cy - hit / 2, width: CGFloat(seam.width), height: hit)
            }
            addSubview(handle)   // re-add → frontmost, above the surfaces
            handle.subviews.forEach { $0.removeFromSuperview() }
            let line = BoxView(bg: t.line2)
            switch divider.axis {
            case .horizontal: line.frame = NSRect(x: (hit - z(1)) / 2, y: 0, width: z(1), height: handle.frame.height)
            case .vertical: line.frame = NSRect(x: 0, y: (hit - z(1)) / 2, width: handle.frame.width, height: z(1))
            }
            handle.addSubview(line)
            window?.invalidateCursorRects(for: handle)
        }
        for (key, handle) in dividerHandles where !live.contains(key) {
            handle.removeFromSuperview(); dividerHandles[key] = nil
        }
    }

    /// Set the drag closures on a freshly-pooled divider grip once. They read the grip's current
    /// `path`/`extent`/`axis` (refreshed each layout) and capture the gesture's start fraction once so
    /// the direction can't flip mid-drag (#65); the seam moves live and persists on release.
    private func configureDividerHandle(_ handle: PaneDividerHandle) {
        handle.onBegin = { [weak self, weak handle] in
            guard let self, let handle, let tab = self.tabs.activeID else { return }
            self.dragTabId = tab
            self.dragPath = handle.path
            self.dragExtent = max(1, handle.extent)
            self.dragSign = (handle.axis == .horizontal) ? 1 : -1
            self.dragFloor = (handle.axis == .horizontal) ? SplitLayout.minPane : SplitLayout.minTerminalHeight
            self.dragStartFraction = self.trees[tab]?.fraction(at: handle.path) ?? 0.5
        }
        handle.onDrag = { [weak self] delta in
            guard let self, let tab = self.dragTabId, let tree = self.trees[tab] else { return }
            let raw = self.dragStartFraction + self.dragSign * Double(delta) / self.dragExtent
            let clamped = SplitLayout.clampFraction(raw, total: self.dragExtent, minPane: self.dragFloor)
            self.trees[tab] = tree.setFraction(at: self.dragPath, to: clamped)
            self.needsLayout = true
        }
        handle.onEnd = { [weak self] in self?.snapshotTabs() }
    }

    /// Outline the focused pane when a tab is split; hide the ring for a single-pane tab so the
    /// common case looks unchanged. The ring is click-through (`PaneFocusRingView`) so it never
    /// blocks the surface beneath it.
    private func layoutFocusRing(tabId: UUID, multiPane: Bool, framesByPane: [UUID: NSRect]) {
        guard store.terminalFocusRing, multiPane, let focused = focusedPane[tabId] ?? trees[tabId]?.firstLeaf,
              let frame = framesByPane[focused] else { focusRing.isHidden = true; return }
        focusRing.isHidden = false
        focusRing.frame = frame
        focusRing.layer?.borderColor = Status.green.cgColor
        focusRing.layer?.borderWidth = z(1.5)
        focusRing.layer?.cornerRadius = z(2)
        addSubview(focusRing)   // re-add → frontmost
    }

    private func pathKey(_ path: [Int]) -> String { path.map(String.init).joined(separator: ".") }

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
            tabRowsById.removeAll()   // rebuilt each layout; keyed by tab id for the drag reflow (#87)
            for tabId in tabs.ids {
                guard let session = representativeSession(tabId) else { continue }
                let tw = tabWidth(for: session.title)
                let row = tabView(tabId: tabId, session: session, width: tw, barH: barH, x: x)
                tabRowsById[tabId] = row
                doc.addSubview(row)
                if tabId == tabs.activeID { activeRect = NSRect(x: x, y: 0, width: tw, height: barH) }
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

    /// Whether any pane in the tab has a pending activity badge (#74) — the strip flags the whole tab.
    private func tabHasBell(_ tabId: UUID) -> Bool {
        (trees[tabId]?.leafIDs ?? []).contains { views[$0]?.hasBell == true }
    }

    /// The busy indicator to draw in a tab's dot slot, or `nil` to fall back to the dot: a
    /// determinate ring for a reported percentage, a spinner once an indeterminate report has
    /// cleared the debounce (`busyShown`), nothing while idle or still debouncing (#94).
    private func busyIndicator(for session: TerminalSession) -> NSProgressIndicator? {
        switch session.busy {
        case .determinate(let percent): return makeProgressRing(size: z(14), percent: percent)
        case .indeterminate where session.busyShown: return makeSpinner(size: z(14))
        default: return nil   // .idle, or .indeterminate still inside the debounce window
        }
    }

    private func tabView(tabId: UUID, session: TerminalSession, width tw: CGFloat, barH: CGFloat, x: CGFloat) -> ClickRow {
        let t = store.theme
        let active = tabId == tabs.activeID
        // The active tab reads as a continuation of the surface below it, so it shares the terminal bg.
        let tab = ClickRow(bg: active ? t.termBg : nil)
        tab.hoverColor = active ? nil : t.hover
        tab.frame = NSRect(x: x, y: 0, width: tw, height: barH)
        // Click/rename is routed through the drag grip below (so a press can become a drag); the
        // bare `ClickRow` keeps only its hover fill.

        // A background tab where *any* pane rang/notified reads as "wants attention": amber underline +
        // dot, mirroring the active tab's green underline (#74). The active tab never flags.
        let flagged = tabHasBell(tabId) && !active
        let underline = BoxView(bg: active ? Status.green : (flagged ? Status.yellow : .clear))
        underline.frame = NSRect(x: 0, y: barH - z(2), width: tw, height: z(2)); tab.addSubview(underline)
        // A busy surface swaps the status dot for a spinner (indeterminate progress) or a ring
        // (determinate 0–99%) while the user has the setting on (#93/#94). The indicator is centered
        // on the dot's slot and self-stops when the next strip rebuild removes it (see `makeSpinner`
        // / `makeProgressRing`); busy is independent of `flagged`, so a busy tab spins even if it
        // also rang the bell. Without an indicator the existing amber/normal dot is drawn.
        if store.terminalBusySpinner, let indicator = busyIndicator(for: session) {
            indicator.frame.origin = NSPoint(x: z(13) + (z(7) - z(14)) / 2, y: (barH - z(14)) / 2)
            tab.addSubview(indicator)
        } else {
            let d = Dot(flagged ? Status.yellow : session.dot, z(7)); d.frame.origin = NSPoint(x: z(13), y: (barH - z(7)) / 2); tab.addSubview(d)
        }
        let nameFrame = NSRect(x: z(28), y: z(8), width: tw - z(28) - z(24), height: z(16))
        if tabId == editingTabId {
            tab.addSubview(renameEditor(session.title, frame: nameFrame, t: t))
        } else {
            let nm = label(session.title, sys(11.5, active ? .semibold : .regular), active ? t.txt : t.txt3)
            nm.frame = nameFrame; tab.addSubview(nm)
        }

        // Whole-tab drag handle (#87): a press becomes a reorder past the threshold, else a plain
        // select/rename click. Added over the label/dot but *under* the close × (added next), so
        // close stays clickable; skipped while renaming so the inline editor keeps the clicks.
        if tabId != editingTabId {
            let grip = DragGrip(frame: tab.bounds)
            grip.onDown = { [weak self] e in self?.tabMouseDown(id: tabId, event: e) }
            grip.onDrag = { [weak self] e in self?.tabMouseDragged(event: e) }
            grip.onUp = { [weak self] _ in self?.tabMouseUp(id: tabId) }
            tab.addSubview(grip)
        }

        // Per-tab close (×) — closes the whole tab (all its panes). Sits above the tab, so its click
        // closes without also selecting.
        let close = ClickRow(radius: z(4))
        close.hoverColor = t.hover
        close.frame = NSRect(x: tw - z(22), y: (barH - z(18)) / 2, width: z(18), height: z(18))
        close.onClick = { [weak self] in self?.requestCloseTab(id: tabId) }
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

    /// A tab's rendered width is a pure function of its (representative pane's) title, so it's stable
    /// across a drag.
    private func tabWidth(forId id: UUID) -> CGFloat { tabWidth(for: representativeSession(id)?.title ?? "") }

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
