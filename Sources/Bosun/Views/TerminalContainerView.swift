import AppKit
import Domain

/// Drag-to-resize grip at the top edge of the terminal.
final class DragHandle: FlippedView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var startY: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with e: NSEvent) { startY = e.locationInWindow.y; onBegin?() }
    override func mouseDragged(with e: NSEvent) { onDrag?(e.locationInWindow.y - startY) }
    override func mouseUp(with e: NSEvent) { onEnd?() }
}

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

    init(view: NSView, title: String, dot: NSColor, origin: TabOrigin, lockTitle: Bool = false) {
        self.view = view
        self.title = title
        self.dot = dot
        self.origin = origin
        self.lockTitle = lockTitle
    }

    var surfaceView: GhosttySurfaceView? { view as? GhosttySurfaceView }
}

/// Terminal dock: drag handle + live tab strip + the active libghostty surface. Order and active
/// selection are delegated to the pure `TerminalTabs` model (unit-tested in Domain); this view
/// only owns the id→surface mapping and the AppKit chrome. Closing the last tab opens a fresh
/// local one so the dock is never empty and `exit` never quits the app.
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

    /// Horizontal-scroll state for the tab strip (#21). The strip is rebuilt every `layout()`, so the
    /// scroll view is too; `tabScroll` is the live one (weak — it's owned by the bar) read at the top
    /// of the next `layout()` to carry the user's manual scroll offset across a plain repaint.
    /// `lastFocusedTabId` is the tab we last auto-scrolled into view, so we only reveal the active tab
    /// when it actually changes (not on every relabel) — the same shape as `RepoPanelView.focusedItemId`.
    private weak var tabScroll: NSScrollView?
    private var lastFocusedTabId: UUID?

    var onRelayout: (() -> Void)?

    private let handle = DragHandle()
    private var startHeight: CGFloat = 240

    /// The theme key whose palette was last pushed to libghostty. `syncTerminalTheme` runs on every
    /// store notify (selection, data, …), so this lets it skip the config rebuild unless the theme
    /// actually changed. Seeded to the default the first surface is created with in `GhosttyApp.start()`.
    private var lastThemeKey = "operator"

    init(store: Store, ghostty: GhosttyApp) {
        self.store = store
        self.ghostty = ghostty
        self.available = ghostty.availability.isReady
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(handle)
        handle.onBegin = { [weak self] in self?.startHeight = self?.store.terminalHeight ?? 240 }
        handle.onDrag = { [weak self] dy in
            guard let self else { return }
            self.store.terminalHeight = max(120, min(760, self.startHeight + dy))
            self.onRelayout?()
        }
        // Persist the final height once the drag ends, not on every frame.
        handle.onEnd = { [weak self] in self?.store.persist() }

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

    /// Re-skin the live terminal to the current theme: rebuild the libghostty palette and push it to
    /// the app + every open surface. A no-op unless the theme changed since the last push, so it's
    /// cheap to call from the general theme/relayout path (issue #9). The dock chrome re-reads the
    /// theme in `layout()`, so it updates separately via `apply()`.
    func syncTerminalTheme() {
        guard available, store.themeKey != lastThemeKey else { return }
        lastThemeKey = store.themeKey
        guard let cfg = ghostty.applyPalette(store.theme.terminalPalette) else { return }
        for session in views.values { session.surfaceView?.updateConfig(cfg) }
        ghostty.tick()   // nudge a repaint with the new colors
    }

    var activeSurfaceView: GhosttySurfaceView? {
        tabs.activeID.flatMap { views[$0]?.surfaceView }
    }

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
        switch conn.kind {
        case let .ssh(host, port, user):
            command = SSHCommand.command(host: host, port: port, user: user, custom: conn.customCommand)
            workingDirectory = nil
        case let .localFolder(path):
            command = nil
            workingDirectory = (path as NSString).expandingTildeInPath
        }
        let surface = GhosttySurfaceView(app: app, command: command, workingDirectory: workingDirectory)
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
        let surface = GhosttySurfaceView(app: app)
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
        return session
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
        window?.makeFirstResponder(view)
    }

    private func refresh() {
        needsLayout = true
        onRelayout?()
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

        // Keep the handle + every session view; rebuild only the chrome (strip, status, grip).
        let keep = Set(views.values.map { ObjectIdentifier($0.view) }).union([ObjectIdentifier(handle)])
        subviews.filter { !keep.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        for session in views.values where session.view.superview !== self {
            addSubview(session.view, positioned: .below, relativeTo: handle)
        }

        handle.frame = NSRect(x: 0, y: 0, width: w, height: 7)
        let grip = BoxView(bg: t.txt5, radius: 1.5)
        grip.frame = NSRect(x: (w - 34) / 2, y: 2, width: 34, height: 3)
        handle.subviews.forEach { $0.removeFromSuperview() }
        handle.addSubview(grip)

        let barH: CGFloat = 32
        layoutTabBar(w: w, y: 7, barH: barH, priorOffset: priorTabOffset)

        // Active surface fills the rest; inactive sessions stay attached but hidden (so their
        // libghostty surfaces keep their Metal layers instead of being torn down on every switch).
        let top = 7 + barH
        let activeID = tabs.activeID
        for session in views.values {
            let active = session.id == activeID
            session.view.isHidden = !active
            if active { session.view.frame = NSRect(x: 0, y: top, width: w, height: max(0, h - top)) }
        }
    }

    private func layoutTabBar(w: CGFloat, y: CGFloat, barH: CGFloat, priorOffset: NSPoint?) {
        let t = store.theme
        let bar = FlippedView(frame: NSRect(x: 0, y: y, width: w, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = t.panel.cgColor
        let topB = BoxView(bg: t.line); topB.frame = NSRect(x: 0, y: 0, width: w, height: 1); bar.addSubview(topB)
        let botB = BoxView(bg: t.line2); botB.frame = NSRect(x: 0, y: barH - 1, width: w, height: 1); bar.addSubview(botB)

        if available {
            // Tabs + the `+` button live in a scrolling document so they stay reachable when they
            // overflow the window width (#21). The doc is inset to clear the pinned resize chevron.
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w - 36, height: barH))
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = false   // a horizontal-only strip; never reserve vertical space
            scroll.autohidesScrollers = true     // only show the bar when the tabs actually overflow
            // Legacy (not overlay) so the slim indicator stays *persistently* visible while overflowing,
            // and renders identically regardless of the system "Show scroll bars" setting — overlay would
            // fade out when idle and, under a mouse, the system can still present a fat legacy bar. The
            // default legacy scroller is ~15pt and would swamp the 32pt strip, so ThinScroller pins it to
            // ~7pt (the bar's bottom border is drawn on `bar`, not here, so it's unaffected). (#21 follow-up)
            scroll.scrollerStyle = .legacy
            scroll.horizontalScrollElasticity = .allowed
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScroller = ThinScroller()

            let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w - 36, height: barH))
            var x: CGFloat = 0
            var activeRect: NSRect?
            for session in orderedSessions {
                let tw = tabWidth(for: session.title)
                doc.addSubview(tabView(session, width: tw, barH: barH, x: x))
                if session.id == tabs.activeID { activeRect = NSRect(x: x, y: 0, width: tw, height: barH) }
                x += tw
            }
            // New local tab. Trailing slack keeps the `+` off the right edge of the document.
            let plus = ClickRow(bg: nil)
            plus.hoverColor = t.hover
            plus.frame = NSRect(x: x + 4, y: 5, width: 22, height: barH - 10)
            plus.onClick = { [weak self] in self?.openLocalTab() }
            let pl = label("+", sys(15), t.txt4, align: .center)
            pl.frame = plus.bounds; plus.addSubview(pl)
            doc.addSubview(plus)

            // Document height must equal the clip height exactly — a taller flipped doc anchors to the
            // top and can spawn a stray vertical scroller. Width spans the tabs + the `+` button extent.
            doc.frame = NSRect(x: 0, y: 0, width: x + 4 + 22 + 4, height: barH)
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
                DispatchQueue.main.async { [weak doc] in doc?.scrollToVisible(rect.insetBy(dx: -24, dy: 0)) }
            } else if tabs.activeID == nil {
                lastFocusedTabId = nil
            }
        } else {
            let nm = label("terminal unavailable", sys(11.5), t.txt3)
            nm.frame = NSRect(x: 14, y: 8, width: w - 28, height: 16); bar.addSubview(nm)
        }

        // Resize chevron pinned at the far right, OUTSIDE the scroll view so it's never scrolled off.
        // There's no duplicate status text here anymore — each tab already carries its own title, and
        // the old right-aligned status label sat on top of the rightmost tab's × button.
        let chevron = label(store.terminalHeight > 500 ? "⌄" : "⌃", sys(12), t.txt3, align: .center)
        let chevBtn = ClickRow(bg: nil)
        chevBtn.frame = NSRect(x: w - 28, y: 6, width: 20, height: 20)
        chevron.frame = chevBtn.bounds; chevBtn.addSubview(chevron)
        chevBtn.onClick = { [weak self] in
            guard let self else { return }
            self.store.terminalHeight = self.store.terminalHeight > 500 ? 240 : 700
            self.onRelayout?()
            self.store.persist()
        }
        bar.addSubview(chevBtn)
        addSubview(bar)
    }

    private func tabWidth(for title: String) -> CGFloat {
        // Glyph dot + label + close button, clamped so long titles (ssh hosts) don't dominate.
        min(200, max(86, fitW(title, sys(11.5, .semibold)) + 56))
    }

    private func tabView(_ session: TerminalSession, width tw: CGFloat, barH: CGFloat, x: CGFloat) -> ClickRow {
        let t = store.theme
        let active = session.id == tabs.activeID
        // The active tab reads as a continuation of the surface below it, so it shares the terminal bg.
        let tab = ClickRow(bg: active ? t.termBg : nil)
        tab.hoverColor = active ? nil : t.hover
        tab.frame = NSRect(x: x, y: 0, width: tw, height: barH)
        tab.onClick = { [weak self] in self?.handleTabClick(id: session.id) }

        let underline = BoxView(bg: active ? Status.green : .clear)
        underline.frame = NSRect(x: 0, y: barH - 2, width: tw, height: 2); tab.addSubview(underline)
        let d = Dot(session.dot, 7); d.frame.origin = NSPoint(x: 13, y: (barH - 7) / 2); tab.addSubview(d)
        let nameFrame = NSRect(x: 28, y: 8, width: tw - 28 - 24, height: 16)
        if session.id == editingTabId {
            tab.addSubview(renameEditor(session.title, frame: nameFrame, t: t))
        } else {
            let nm = label(session.title, sys(11.5, active ? .semibold : .regular), active ? t.txt : t.txt3)
            nm.frame = nameFrame; tab.addSubview(nm)
        }

        // Per-tab close (×). Sits above the tab, so its click closes without also selecting.
        let close = ClickRow(radius: 4)
        close.hoverColor = t.hover
        close.frame = NSRect(x: tw - 22, y: (barH - 18) / 2, width: 18, height: 18)
        close.onClick = { [weak self] in self?.requestCloseTab(id: session.id) }
        let xl = label("×", sys(13), t.txt3, align: .center)
        xl.frame = close.bounds; close.addSubview(xl)
        tab.addSubview(close)

        let sep = BoxView(bg: t.line); sep.frame = NSRect(x: tw - 1, y: 0, width: 1, height: barH); tab.addSubview(sep)
        return tab
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
