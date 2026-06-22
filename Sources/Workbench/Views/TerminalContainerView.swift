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

/// One terminal tab: a live libghostty surface (or the unavailable placeholder) plus its label.
final class TerminalSession {
    let id = UUID()
    let view: NSView
    var title: String
    var dot: NSColor

    init(view: NSView, title: String, dot: NSColor) {
        self.view = view
        self.title = title
        self.dot = dot
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
        if available {
            register(makeLocalSession())
        } else if case .unavailable(let stage) = ghostty.availability {
            register(TerminalSession(view: TerminalUnavailableView(stage: stage),
                                     title: "terminal", dot: Status.red))
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

    /// Open a new connection tab and focus it: `command` runs in place of the shell (an SSH
    /// session), `workingDirectory` starts the shell in a folder (a local-folder connection).
    func openConnection(command: String? = nil, workingDirectory: String? = nil, title: String) {
        guard available, let app = ghostty.app else { return }
        let surface = GhosttySurfaceView(app: app, command: command, workingDirectory: workingDirectory)
        add(wire(TerminalSession(view: surface, title: title, dot: Status.green), surface: surface))
    }

    /// Jump to another tab (native ⌘1…9 / next / previous / last).
    func gotoTab(_ jump: TabJump) {
        let before = tabs.activeID
        tabs.goto(jump)
        guard tabs.activeID != before else { return }
        refresh()
        focusActive()
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
                                   title: "terminal", dot: Status.red)
        }
        let surface = GhosttySurfaceView(app: app)
        return wire(TerminalSession(view: surface, title: "zsh", dot: Status.green), surface: surface)
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

    /// Insert a prepared session into the model + map (no relayout); used to seed the first tab.
    private func register(_ session: TerminalSession) {
        views[session.id] = session
        tabs.open(session.id)
    }

    private func add(_ session: TerminalSession) {
        register(session)
        refresh()
        focusActive()
    }

    private func updateTitle(id: UUID, _ title: String) {
        guard let session = views[id] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session.title != trimmed else { return }
        session.title = trimmed
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
            add(makeLocalSession())
            return
        }
        refresh()
        focusActive()
    }

    private func selectSession(id: UUID) {
        guard tabs.activeID != id else { return }
        tabs.select(id)
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
        layoutTabBar(w: w, y: 7, barH: barH)

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

    private func layoutTabBar(w: CGFloat, y: CGFloat, barH: CGFloat) {
        let t = store.theme
        let bar = FlippedView(frame: NSRect(x: 0, y: y, width: w, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = t.panel.cgColor
        let topB = BoxView(bg: t.line); topB.frame = NSRect(x: 0, y: 0, width: w, height: 1); bar.addSubview(topB)
        let botB = BoxView(bg: t.line2); botB.frame = NSRect(x: 0, y: barH - 1, width: w, height: 1); bar.addSubview(botB)

        if available {
            var x: CGFloat = 0
            for session in orderedSessions {
                let tw = tabWidth(for: session.title)
                bar.addSubview(tabView(session, width: tw, barH: barH, x: x))
                x += tw
            }
            // New local tab.
            let plus = ClickRow(bg: nil)
            plus.hoverColor = t.hover
            plus.frame = NSRect(x: x + 4, y: 5, width: 22, height: barH - 10)
            plus.onClick = { [weak self] in self?.openLocalTab() }
            let pl = label("+", sys(15), t.txt4, align: .center)
            pl.frame = plus.bounds; plus.addSubview(pl)
            bar.addSubview(plus)
        } else {
            let nm = label("terminal unavailable", sys(11.5), t.txt3)
            nm.frame = NSRect(x: 14, y: 8, width: w - 28, height: 16); bar.addSubview(nm)
        }

        // Resize chevron at the far right. There's no duplicate status text here anymore — each
        // tab already carries its own title, and the old right-aligned status label sat on top of
        // the rightmost tab's × button, making that tab impossible to close.
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
        tab.onClick = { [weak self] in self?.selectSession(id: session.id) }

        let underline = BoxView(bg: active ? Status.green : .clear)
        underline.frame = NSRect(x: 0, y: barH - 2, width: tw, height: 2); tab.addSubview(underline)
        let d = Dot(session.dot, 7); d.frame.origin = NSPoint(x: 13, y: (barH - 7) / 2); tab.addSubview(d)
        let nm = label(session.title, sys(11.5, active ? .semibold : .regular), active ? t.txt : t.txt3)
        nm.frame = NSRect(x: 28, y: 8, width: tw - 28 - 24, height: 16); tab.addSubview(nm)

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
}
