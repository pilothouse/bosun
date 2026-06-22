import AppKit
import Domain

/// Drag-to-resize grip at the top edge of the terminal.
final class DragHandle: FlippedView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var startY: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with e: NSEvent) { startY = e.locationInWindow.y; onBegin?() }
    override func mouseDragged(with e: NSEvent) { onDrag?(e.locationInWindow.y - startY) }
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

/// Terminal dock: drag handle + live tab strip + the active libghostty surface. Manages a set of
/// sessions (local shells and SSH connections); closing the last tab opens a fresh local one so the
/// dock is never empty and `exit` never quits the app.
final class TerminalContainerView: FlippedView {
    let store: Store
    private let ghostty: GhosttyApp
    private let available: Bool

    private var sessions: [TerminalSession] = []
    private var activeId: UUID?

    var onRelayout: (() -> Void)?

    private let handle = DragHandle()
    private var startHeight: CGFloat = 240

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

        // Seed the dock with one session. When libghostty is down, that's the error placeholder.
        if available {
            let s = makeLocalSession()
            sessions = [s]
            activeId = s.id
        } else if case .unavailable(let stage) = ghostty.availability {
            sessions = [TerminalSession(view: TerminalUnavailableView(stage: stage),
                                        title: "terminal", dot: Status.red)]
            activeId = sessions.first?.id
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }

    var activeSurfaceView: GhosttySurfaceView? {
        sessions.first { $0.id == activeId }?.surfaceView
    }

    // MARK: Session lifecycle

    /// Open a new local-shell tab and focus it.
    func openLocalTab() {
        guard available else { return }
        add(makeLocalSession())
    }

    /// Open a new tab that runs `command` (e.g. an SSH session), labelled `title`, and focus it.
    func openConnection(command: String, title: String) {
        guard available, let app = ghostty.app else { return }
        let g = GhosttySurfaceView(app: app, command: command)
        add(wire(TerminalSession(view: g, title: title, dot: Status.green), surface: g))
    }

    private func makeLocalSession() -> TerminalSession {
        guard let app = ghostty.app else {
            return TerminalSession(view: TerminalUnavailableView(stage: .application),
                                   title: "terminal", dot: Status.red)
        }
        let g = GhosttySurfaceView(app: app)
        return wire(TerminalSession(view: g, title: "zsh", dot: Status.green), surface: g)
    }

    /// Hook a surface's lifecycle callbacks back to this dock, keyed by the session id.
    private func wire(_ session: TerminalSession, surface: GhosttySurfaceView) -> TerminalSession {
        let id = session.id
        // close_surface_cb fires inside ghostty_app_tick; defer the alert + teardown off the tick
        // so we don't free the surface (or spin a modal) while libghostty is still on the stack.
        surface.onChildExit = { [weak self] processAlive in
            DispatchQueue.main.async { self?.requestClose(id: id, processAlive: processAlive) }
        }
        surface.onTitleChange = { [weak self] title in
            self?.updateTitle(id: id, title)
        }
        return session
    }

    private func add(_ session: TerminalSession) {
        sessions.append(session)
        activeId = session.id
        refresh()
        focusActive()
    }

    private func updateTitle(id: UUID, _ title: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, s.title != trimmed else { return }
        s.title = trimmed
        needsLayout = true   // relabel the tab strip; no surface churn
    }

    /// Close requested by libghostty (`exit`) or the tab's × button. Confirms first when a
    /// foreground process is still running, then tears the tab down.
    private func requestClose(id: UUID, processAlive: Bool) {
        guard sessions.contains(where: { $0.id == id }) else { return }   // already gone
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
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let closing = sessions.remove(at: idx)
        closing.view.removeFromSuperview()   // drops the last strong ref → deinit frees the surface

        if activeId == id {
            // Prefer the tab that shifted into this slot, else the new last tab.
            activeId = (sessions.indices.contains(idx) ? sessions[idx] : sessions.last)?.id
        }
        // Never leave the dock empty (and so never let the last `exit` quit the app).
        if sessions.isEmpty, available {
            let s = makeLocalSession()
            sessions = [s]
            activeId = s.id
        }
        refresh()
        focusActive()
    }

    private func selectSession(id: UUID) {
        guard activeId != id else { return }
        activeId = id
        refresh()
        focusActive()
    }

    private func focusActive() {
        guard let v = activeSurfaceView else { return }
        window?.makeFirstResponder(v)
    }

    private func refresh() {
        needsLayout = true
        onRelayout?()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        layer?.backgroundColor = NSColor.hex(0x0a0c0f).cgColor

        // Keep the handle + every session view; rebuild only the chrome (strip, status, grip).
        let keep = Set(sessions.map { ObjectIdentifier($0.view) } + [ObjectIdentifier(handle)])
        subviews.filter { !keep.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        for s in sessions where s.view.superview !== self { addSubview(s.view, positioned: .below, relativeTo: handle) }

        handle.frame = NSRect(x: 0, y: 0, width: w, height: 7)
        let grip = BoxView(bg: .whiteA(0.18), radius: 1.5)
        grip.frame = NSRect(x: (w - 34) / 2, y: 2, width: 34, height: 3)
        handle.subviews.forEach { $0.removeFromSuperview() }
        handle.addSubview(grip)

        let barH: CGFloat = 32
        layoutTabBar(w: w, y: 7, barH: barH)

        // Active surface fills the rest; inactive sessions stay attached but hidden (so their
        // libghostty surfaces keep their Metal layers instead of being torn down on every switch).
        let top = 7 + barH
        for s in sessions {
            let active = s.id == activeId
            s.view.isHidden = !active
            if active { s.view.frame = NSRect(x: 0, y: top, width: w, height: max(0, h - top)) }
        }
    }

    private func layoutTabBar(w: CGFloat, y: CGFloat, barH: CGFloat) {
        let bar = FlippedView(frame: NSRect(x: 0, y: y, width: w, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.hex(0x101318).cgColor
        let topB = BoxView(bg: .whiteA(0.05)); topB.frame = NSRect(x: 0, y: 0, width: w, height: 1); bar.addSubview(topB)
        let botB = BoxView(bg: .whiteA(0.06)); botB.frame = NSRect(x: 0, y: barH - 1, width: w, height: 1); bar.addSubview(botB)

        if available {
            var x: CGFloat = 0
            for s in sessions {
                let tw = tabWidth(for: s.title)
                bar.addSubview(tabView(s, width: tw, barH: barH, x: x))
                x += tw
            }
            // New local tab.
            let plus = ClickRow(bg: nil)
            plus.hoverColor = .whiteA(0.06)
            plus.frame = NSRect(x: x + 4, y: 5, width: 22, height: barH - 10)
            plus.onClick = { [weak self] in self?.openLocalTab() }
            let pl = label("+", sys(15), .hex(0x5b616b), align: .center)
            pl.frame = plus.bounds; plus.addSubview(pl)
            bar.addSubview(plus)
        } else {
            let nm = label("terminal unavailable", sys(11.5), .hex(0x8a909a))
            nm.frame = NSRect(x: 14, y: 8, width: w - 28, height: 16); bar.addSubview(nm)
        }

        // Right status — reflects the active session.
        let activeTitle = sessions.first { $0.id == activeId }?.title ?? "terminal"
        let statusText = available ? "● \(activeTitle)" : "● terminal unavailable"
        let stl = label(statusText, mono(10), available ? Status.green : Status.red, align: .right)
        let chevron = label(store.terminalHeight > 500 ? "⌄" : "⌃", sys(12), .hex(0x9aa0aa), align: .center)
        let chevBtn = ClickRow(bg: nil)
        chevBtn.frame = NSRect(x: w - 28, y: 6, width: 20, height: 20)
        chevron.frame = chevBtn.bounds; chevBtn.addSubview(chevron)
        chevBtn.onClick = { [weak self] in
            guard let self else { return }
            self.store.terminalHeight = self.store.terminalHeight > 500 ? 240 : 700
            self.onRelayout?()
        }
        stl.frame = NSRect(x: w - 28 - 320, y: 9, width: 312, height: 14); bar.addSubview(stl)
        bar.addSubview(chevBtn)
        addSubview(bar)
    }

    private func tabWidth(for title: String) -> CGFloat {
        // Glyph dot + label + close button, clamped so long titles (ssh hosts) don't dominate.
        min(200, max(86, fitW(title, sys(11.5, .semibold)) + 56))
    }

    private func tabView(_ s: TerminalSession, width tw: CGFloat, barH: CGFloat, x: CGFloat) -> ClickRow {
        let active = s.id == activeId
        let tab = ClickRow(bg: active ? .hex(0x0a0c0f) : nil)
        tab.hoverColor = active ? nil : .whiteA(0.04)
        tab.frame = NSRect(x: x, y: 0, width: tw, height: barH)
        tab.onClick = { [weak self] in self?.selectSession(id: s.id) }

        let underline = BoxView(bg: active ? Status.green : .clear)
        underline.frame = NSRect(x: 0, y: barH - 2, width: tw, height: 2); tab.addSubview(underline)
        let d = Dot(s.dot, 7); d.frame.origin = NSPoint(x: 13, y: (barH - 7) / 2); tab.addSubview(d)
        let nm = label(s.title, sys(11.5, active ? .semibold : .regular), active ? .hex(0xe6e8ec) : .hex(0x8a909a))
        nm.frame = NSRect(x: 28, y: 8, width: tw - 28 - 24, height: 16); tab.addSubview(nm)

        // Per-tab close (×). Sits above the tab, so its click closes without also selecting.
        let close = ClickRow(radius: 4)
        close.hoverColor = .whiteA(0.12)
        close.frame = NSRect(x: tw - 22, y: (barH - 18) / 2, width: 18, height: 18)
        close.onClick = { [weak self] in
            let alive = s.surfaceView?.needsConfirmQuit ?? false
            self?.requestClose(id: s.id, processAlive: alive)
        }
        let xl = label("×", sys(13), .hex(0x8a909a), align: .center)
        xl.frame = close.bounds; close.addSubview(xl)
        tab.addSubview(close)

        let sep = BoxView(bg: .whiteA(0.05)); sep.frame = NSRect(x: tw - 1, y: 0, width: 1, height: barH); tab.addSubview(sep)
        return tab
    }
}
