import AppKit

final class TitlebarView: FlippedView {
    let store: Store
    var onToggleSidebar: (() -> Void)?
    var onToggleSettings: (() -> Void)?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }
    override func layout() { super.layout(); rebuild() }

    private func iconButton(_ symbol: String, tint: NSColor, frame: NSRect, point: CGFloat = 14) -> ClickRow {
        let row = ClickRow(radius: 6)
        row.hoverColor = store.theme.hover
        row.frame = frame
        let iv = NSImageView(frame: row.bounds.insetBy(dx: frame.width/2 - 9, dy: frame.height/2 - 9))
        iv.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iv.contentTintColor = tint
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: point, weight: .regular)
        row.addSubview(iv)
        return row
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        let h = bounds.height
        layer?.backgroundColor = t.bar.cgColor

        let border = BoxView(bg: t.line)
        border.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        addSubview(border)

        // Left group (leave ~78pt for the traffic lights).
        var x: CGFloat = 78
        let toggle = iconButton("sidebar.left",
                                tint: store.railCollapsed ? t.accent : t.txt3,
                                frame: NSRect(x: x, y: (h - 24) / 2, width: 30, height: 24), point: 15)
        toggle.onClick = { [weak self] in self?.onToggleSidebar?() }
        addSubview(toggle)
        x += 40

        let sq = Dot(t.accent, 14, radius: 4)
        sq.frame.origin = NSPoint(x: x, y: (h - 14) / 2)
        addSubview(sq)
        x += 22

        let name = label(store.selectedConn.name, sys(12.5, .semibold), t.txt)
        name.frame = NSRect(x: x, y: (h - 16) / 2, width: fitW(name), height: 16)
        addSubview(name)
        x += name.frame.width + 7

        let slash = label("/", sys(12.5), t.txt4)
        slash.frame = NSRect(x: x, y: (h - 16) / 2, width: 8, height: 16)
        addSubview(slash)
        x += 13

        let repo = label("acme/api-gateway", sys(12.5), t.txt3)
        repo.frame = NSRect(x: x, y: (h - 16) / 2, width: fitW(repo), height: 16)
        addSubview(repo)

        // Right group.
        var rx = bounds.width - 13
        let gear = iconButton("gearshape", tint: t.txt3,
                              frame: NSRect(x: rx - 28, y: (h - 28) / 2, width: 28, height: 28), point: 15)
        gear.onClick = { [weak self] in self?.onToggleSettings?() }
        addSubview(gear)
        rx -= 28 + 8

        // Session pill.
        let running = store.connections.filter { $0.sessionLabel.contains("running") || $0.sessionLabel.contains("claude") }.count
        let pillText = "\(running) sessions · synced to iCloud"
        let pillLabel = label(pillText, sys(11.5, .medium), t.txt3)
        let pw = fitW(pillLabel)
        let pill = BoxView(bg: t.card, radius: 7, border: t.cardbr)
        let pillW = pw + 32
        pill.frame = NSRect(x: rx - pillW, y: (h - 26) / 2, width: pillW, height: 26)
        let gdot = Dot(Status.green, 7)
        gdot.frame.origin = NSPoint(x: 11, y: (26 - 7) / 2)
        pill.addSubview(gdot)
        pillLabel.frame = NSRect(x: 24, y: 0, width: pw, height: 26)
        pill.addSubview(pillLabel)
        addSubview(pill)
    }
}
