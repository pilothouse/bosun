import AppKit

/// Drag-to-resize grip at the top edge of the terminal.
final class DragHandle: FlippedView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var startY: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with e: NSEvent) { startY = e.locationInWindow.y; onBegin?() }
    override func mouseDragged(with e: NSEvent) { onDrag?(e.locationInWindow.y - startY) }
}

/// Terminal dock: drag handle + tab strip + the live libghostty surface.
final class TerminalContainerView: FlippedView {
    let store: Store
    let terminalView: NSView          // GhosttySurfaceView or a placeholder
    var onRelayout: (() -> Void)?

    private let handle = DragHandle()
    private var startHeight: CGFloat = 240

    init(store: Store, terminal: NSView) {
        self.store = store
        self.terminalView = terminal
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminal)
        addSubview(handle)
        handle.onBegin = { [weak self] in self?.startHeight = self?.store.terminalHeight ?? 240 }
        handle.onDrag = { [weak self] dy in
            guard let self else { return }
            self.store.terminalHeight = max(120, min(760, self.startHeight + dy))
            self.onRelayout?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        layer?.backgroundColor = NSColor.hex(0x0a0c0f).cgColor

        // Remove only chrome (keep the persistent terminal + handle).
        subviews.filter { $0 !== terminalView && $0 !== handle }.forEach { $0.removeFromSuperview() }

        handle.frame = NSRect(x: 0, y: 0, width: w, height: 7)
        let grip = BoxView(bg: .whiteA(0.18), radius: 1.5)
        grip.frame = NSRect(x: (w - 34) / 2, y: 2, width: 34, height: 3)
        handle.subviews.forEach { $0.removeFromSuperview() }
        handle.addSubview(grip)

        // Tab strip.
        let barH: CGFloat = 32
        let bar = FlippedView(frame: NSRect(x: 0, y: 7, width: w, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.hex(0x101318).cgColor
        let topB = BoxView(bg: .whiteA(0.05)); topB.frame = NSRect(x: 0, y: 0, width: w, height: 1); bar.addSubview(topB)
        let botB = BoxView(bg: .whiteA(0.06)); botB.frame = NSRect(x: 0, y: barH - 1, width: w, height: 1); bar.addSubview(botB)

        var x: CGFloat = 0
        let tabs: [(String, Bool, NSColor)] = [("claude", true, Status.green), ("zsh", false, Status.dim)]
        for (name, active, dotColor) in tabs {
            let tw = name.count <= 4 ? 78.0 : 92.0
            let tab = FlippedView(frame: NSRect(x: x, y: 0, width: CGFloat(tw), height: barH))
            tab.wantsLayer = true
            if active { tab.layer?.backgroundColor = NSColor.hex(0x0a0c0f).cgColor }
            let underline = BoxView(bg: active ? Status.green : .clear)
            underline.frame = NSRect(x: 0, y: barH - 2, width: CGFloat(tw), height: 2); tab.addSubview(underline)
            let d = Dot(dotColor, 7); d.frame.origin = NSPoint(x: 13, y: (barH - 7) / 2); tab.addSubview(d)
            let nm = label(name, sys(11.5, active ? .semibold : .regular), active ? .hex(0xe6e8ec) : .hex(0x8a909a))
            nm.frame = NSRect(x: 28, y: 8, width: CGFloat(tw) - 34, height: 16); tab.addSubview(nm)
            let sep = BoxView(bg: .whiteA(0.05)); sep.frame = NSRect(x: CGFloat(tw) - 1, y: 0, width: 1, height: barH); tab.addSubview(sep)
            bar.addSubview(tab)
            x += CGFloat(tw)
        }
        let plus = label("+", sys(15), .hex(0x5b616b), align: .center)
        plus.frame = NSRect(x: x + 6, y: 7, width: 22, height: 18); bar.addSubview(plus)

        // Right status.
        let host = store.selectedConn.meta
        let statusText = "● running · \(host)"
        let stl = label(statusText, mono(10), Status.green, align: .right)
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

        // Terminal surface fills the rest.
        terminalView.frame = NSRect(x: 0, y: 7 + barH, width: w, height: max(0, h - 7 - barH))
    }
}
