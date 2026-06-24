import AppKit

final class TitlebarView: FlippedView {
    let store: Store
    var onToggleSidebar: (() -> Void)?
    var onTogglePanel: (() -> Void)?
    /// Reload all live data (orgs/repos + the selected repo's items). Wired to the data controller.
    var onRefresh: (() -> Void)?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }
    override func layout() { super.layout(); rebuild() }

    /// Standard titlebar behaviour on the empty background: drag to move the window, and
    /// double-click to zoom / minimise per the user's "Double-click a window's title bar to…"
    /// System Setting (default: zoom — fill the screen, then restore to the previous frame on the
    /// next double-click, exactly like a native titlebar). The icon buttons are `ClickRow`s that
    /// consume their own clicks, so this only fires on the background between them.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.zoom(nil)   // "Maximize" / unset → zoom
            }
            return
        }
        window.performDrag(with: event)
    }

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

        // Align every titlebar icon on the centre line of the macOS traffic lights. Read their
        // real position from the close button so the controls line up exactly with
        // close/minimise/zoom regardless of bar height; fall back to the standard 28pt zone centre
        // before the window/buttons exist.
        let baseCY: CGFloat
        if let close = window?.standardWindowButton(.closeButton), let host = close.superview {
            baseCY = convert(close.frame, from: host).midY
        } else {
            baseCY = min(h, 28) / 2
        }
        let cy = baseCY
        // The breadcrumb labels render their glyphs a touch high in the frame, so they read as
        // tight to the top next to the geometrically-centred icons; nudge just the text down ~2pt.
        let textY = cy - 8 + 2

        let border = BoxView(bg: t.line)
        border.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        addSubview(border)

        // Left group (leave ~78pt for the traffic lights).
        var x: CGFloat = 78
        let toggle = iconButton("sidebar.left",
                                tint: store.railCollapsed ? t.accent : t.txt3,
                                frame: NSRect(x: x, y: cy - 12, width: 30, height: 24), point: 15)
        toggle.onClick = { [weak self] in self?.onToggleSidebar?() }
        toggle.toolTip = store.railCollapsed ? "Show sidebar" : "Hide sidebar"
        addSubview(toggle)
        x += 40

        let name = label(store.selectedConn.name, sys(12.5, .semibold), t.txt)
        name.frame = NSRect(x: x, y: textY, width: fitW(name), height: 16)
        addSubview(name)
        x += name.frame.width + 7

        // Repo breadcrumb: bound to the live selection, shown only once a repo is picked.
        let repoTitle = store.selectedRepoTitle
        if !repoTitle.isEmpty {
            let slash = label("/", sys(12.5), t.txt4)
            slash.frame = NSRect(x: x, y: textY, width: 8, height: 16)
            addSubview(slash)
            x += 13

            let repo = label(repoTitle, sys(12.5), t.txt3)
            repo.frame = NSRect(x: x, y: textY, width: fitW(repo), height: 16)
            addSubview(repo)
        }

        // Right group: mirror of the left sidebar toggle for the organizations panel. Anchored to
        // the right edge so it tracks window resizes; accent tint + flipped tooltip when collapsed.
        let panelToggle = iconButton("sidebar.right",
                                     tint: store.repoPanelCollapsed ? t.accent : t.txt3,
                                     frame: NSRect(x: bounds.width - 40, y: cy - 12, width: 30, height: 24), point: 15)
        panelToggle.onClick = { [weak self] in self?.onTogglePanel?() }
        panelToggle.toolTip = store.repoPanelCollapsed ? "Show organizations" : "Hide organizations"
        addSubview(panelToggle)

        // Global "refresh all", one icon-stride to the left of the organizations toggle. Swaps to a
        // spinner while a refresh is in flight (clicks debounced by the controller's `isRefreshing`).
        let refreshFrame = NSRect(x: bounds.width - 80, y: cy - 12, width: 30, height: 24)
        if store.isRefreshing {
            let row = ClickRow(radius: 6)
            row.frame = refreshFrame
            let spinner = makeSpinner(size: 14)
            spinner.frame = NSRect(x: 8, y: 5, width: 14, height: 14); row.addSubview(spinner)
            addSubview(row)
        } else {
            let refresh = iconButton("arrow.clockwise", tint: t.txt3, frame: refreshFrame, point: 15)
            refresh.onClick = { [weak self] in self?.onRefresh?() }
            refresh.toolTip = "Refresh all"
            addSubview(refresh)
        }
    }
}
