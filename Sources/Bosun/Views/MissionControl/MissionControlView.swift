import AppKit
import Domain

/// Everything one Mission Control layout pass renders from, computed once per pass: the panes, their
/// Domain tiles and item links, the issues/PRs in scope, and which tiles pass the filters (in order).
struct MissionSnapshot {
    let panes: [TerminalSession]
    let tiles: [MissionTile]
    let links: [UUID: String]
    /// Each colored pane's connection color (#102); uncolored and local panes are absent.
    let colors: [UUID: ConnectionColor]
    let items: [Item]
    let visible: [MissionTile]
    /// The active pane's title, shown in the tracker's hint line.
    let focusedTitle: String?

    var visibleIds: [UUID] { visible.compactMap { UUID(uuidString: $0.id) } }
}

/// The Mission Control layout: open terminal panes as live tiles, in one of two views — **Grid** (one
/// page of tiles that exactly fills the area, in the chosen layout preset) or **Focus** (one large live
/// tile beside a list of session cards) — with an optional issue/PR tracker (list or board). It shows
/// while `store.workspaceLayout == .missionControl`; the dock lends it the terminal surfaces.
///
/// Design rules (docs/plans/…-mission-control-v3.md):
/// - The grid never scrolls; extra sessions go to further pages. Pages swap same-size tiles, so a flip
///   doesn't resize (reflow) terminals; off-page tiles are parked hidden at their last size.
/// - The page is *derived from keyboard focus*: it's always the page holding the active pane. Flipping
///   a page moves focus to that page's first tile, so the two can never disagree.
/// - Every region diffs its own inputs and rebuilds only when they change.
/// - The focused tile is never hidden; if it's filtered out, focus moves to the first visible tile.
final class MissionControlView: FlippedView {
    let store: Store
    private let terminal: TerminalContainerView
    private let data: GitHubDataController

    /// Session-only view state (not persisted).
    private var filter: MissionFilter = .all { didSet { needsLayout = true } }
    private var repoKey: String? { didSet { needsLayout = true } }
    /// Links made with "attach focused session" (pane id → item key); they win over title auto-links.
    private var manualLinks: [UUID: String] = [:]
    /// The tracker item selected here (item key `owner/name#n`).
    private var selectedItemKey: String?

    private var tiles: [UUID: MissionTileView] = [:]
    /// Placeholders for a page's empty slots (pooled; "New session" on click).
    private var emptySlots: [MissionEmptySlotView] = []
    /// Visible tiles in display order, and the page size, from the last layout.
    private var visibleOrder: [UUID] = []
    private var perPage = 1
    /// The page shown last, used while focus sits outside the visible tiles.
    private var lastPage = 0
    /// What `auto` resolved to on the last layout — the starting point for More / Fewer Tiles.
    private var resolvedPreset: MissionLayoutPreset = .twoByTwo

    /// The tile being dragged to reorder: its pane, and where in the tile the cursor grabbed it.
    private var drag: (pane: UUID, grab: NSPoint)?
    private var dropTarget: UUID?
    /// Spring-loaded page flip while a drag hovers a pager arrow: the pending flip and its direction.
    private var springFlip: DispatchWorkItem?
    private var springDirection: Int?

    private let bar = MissionBarView()
    private let banner = MissionAttentionBanner()
    private let grid = MissionGridView()
    private let cards = MissionFocusCardsView()
    private let board = MissionBoardView()
    private let tracker = MissionTrackerView()
    private let status = MissionStatusView()

    init(store: Store, terminal: TerminalContainerView, data: GitHubDataController) {
        self.store = store
        self.terminal = terminal
        self.data = data
        super.init(frame: .zero)
        wantsLayer = true
        [grid, cards, board, tracker, banner, bar, status].forEach(addSubview)
        wireRegions()
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }

    private func wireRegions() {
        bar.onView = { [weak self] view in self?.store.missionView = view }
        bar.onPreset = { [weak self] preset in self?.store.missionLayout = preset }
        bar.onFilter = { [weak self] filter in self?.filter = filter }
        bar.onPage = { [weak self] delta in self?.flipPage(delta) }
        bar.onClearRepo = { [weak self] in self?.setRepo(nil) }
        bar.onOptions = { [weak self] anchor in self?.showOptionsMenu(from: anchor) }
        banner.onFocus = { [weak self] id in self?.jump(to: id) }
        cards.onFocus = { [weak self] id in self?.focusTile(id) }
        tracker.onSelect = { [weak self] item in self?.selectItem(item) }
        tracker.onAttach = { [weak self] in self?.attachFocusedSession() }
        tracker.onZoom = { [weak self] in self?.zoomToSelected() }
        board.onSelect = { [weak self] item in self?.selectItem(item) }
    }

    // MARK: Actions (menu / shortcuts / regions)

    /// The page holding the active pane, or the last page shown while focus is elsewhere.
    private var currentPage: Int {
        guard let active = terminal.activePaneId, let index = visibleOrder.firstIndex(of: active) else {
            return MissionPagePolicy.clampPage(lastPage, count: visibleOrder.count, perPage: perPage)
        }
        return MissionPagePolicy.page(ofIndex: index, perPage: perPage)
    }

    /// Move keyboard focus to the next (`+1`) or previous (`-1`) visible tile — across pages.
    func cycleFocus(_ delta: Int) {
        guard !visibleOrder.isEmpty else { return }
        let current = terminal.activePaneId.flatMap { visibleOrder.firstIndex(of: $0) } ?? 0
        focusTile(visibleOrder[MissionTilePolicy.cycle(focus: current, delta: delta, count: visibleOrder.count)])
    }

    /// Show the next / previous page: focus its first tile (the page follows focus). Stops at the ends.
    func flipPage(_ delta: Int) {
        guard store.missionView == .grid else { return }
        let target = MissionPagePolicy.clampPage(currentPage + delta, count: visibleOrder.count, perPage: perPage)
        let range = MissionPagePolicy.range(page: target, perPage: perPage, count: visibleOrder.count)
        guard target != currentPage, let first = range.first else { return }
        focusTile(visibleOrder[first])
    }

    /// More (`+1`) or fewer (`-1`) tiles per page, stepping from the shape on screen.
    func stepLayout(_ delta: Int) {
        let base = store.missionLayout == .auto ? resolvedPreset : store.missionLayout
        store.missionLayout = MissionPagePolicy.step(from: base, by: delta)
    }

    /// Focus the active pane's tile — called right after the layout switches in.
    func focusActiveTile() {
        layoutSubtreeIfNeeded()
        guard let pane = MissionTilePolicy.focusAfterFilter(
            current: terminal.activePaneId?.uuidString, visible: visibleOrder.map(\.uuidString))
            .flatMap(UUID.init(uuidString:)) else { return }
        focusTile(pane)
    }

    private func focusTile(_ paneId: UUID) {
        // A hidden view can't take the keyboard: show the tile first (it may be parked on another page).
        tiles[paneId]?.isHidden = false
        terminal.focusLentPane(paneId)
        needsLayout = true
    }

    /// Jump to a session from the attention banner — widening the filter/scope first if it hides it.
    private func jump(to paneId: UUID) {
        if !visibleOrder.contains(paneId) {
            filter = .all
            repoKey = nil
            layoutSubtreeIfNeeded()
        }
        focusTile(paneId)
    }

    private func selectItem(_ item: Item) {
        selectedItemKey = selectedItemKey == item.missionKey ? nil : item.missionKey
        if selectedItemKey != nil { data.selectItem(item) }   // loads the detail (checks)
        needsLayout = true
    }

    private func setRepo(_ key: String?) {
        repoKey = key
        if let key, let slash = key.firstIndex(of: "/") {
            data.selectRepo(owner: String(key[..<slash]), name: String(key[key.index(after: slash)...]))
        } else {
            data.selectOrg(id: Org.allOrgsID)
        }
    }

    private func showOptionsMenu(from anchor: NSView) {
        let menu = NSMenu()
        let repoItem = NSMenuItem(title: "Repo", action: nil, keyEquivalent: "")
        let repoMenu = NSMenu(title: "Repo")
        repoMenu.addItem(menuItem("All repos", #selector(pickRepo(_:)), state: repoKey == nil))
        repoMenu.addItem(.separator())
        for repo in store.allOrgRepos {
            let key = "\(repo.owner)/\(repo.name)"
            let item = menuItem(key, #selector(pickRepo(_:)), state: repoKey == key)
            item.representedObject = key
            repoMenu.addItem(item)
        }
        repoItem.submenu = repoMenu
        menu.addItem(repoItem)
        menu.addItem(menuItem("Group by repo", #selector(toggleGroupByRepo), state: store.missionGroupByRepo))
        menu.addItem(.separator())
        let trackerTitles: [(MissionTrackerStyle, String)] = [(.off, "Tracker off"), (.list, "Tracker as list"),
                                                             (.board, "Tracker as board")]
        for (style, title) in trackerTitles {
            let item = menuItem(title, #selector(pickTracker(_:)), state: store.missionTracker == style)
            item.representedObject = style.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + z(4)), in: anchor)
    }

    private func menuItem(_ title: String, _ action: Selector, state: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        return item
    }

    @objc private func pickRepo(_ sender: NSMenuItem) { setRepo(sender.representedObject as? String) }
    @objc private func toggleGroupByRepo() { store.missionGroupByRepo.toggle() }
    @objc private func pickTracker(_ sender: NSMenuItem) {
        store.missionTracker = MissionTrackerStyle.stored(sender.representedObject as? String)
    }

    private func attachFocusedSession() {
        guard let pane = terminal.activePaneId, let key = selectedItemKey else { return }
        manualLinks[pane] = key
        needsLayout = true
    }

    private func zoomToSelected() {
        guard let key = selectedItemKey else { return }
        let snap = makeSnapshot()
        store.missionView = .focus
        if let pane = snap.visibleIds.first(where: { snap.links[$0] == key }) { focusTile(pane) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Only while borrowing: once the dock takes its surfaces back, a stray layout must not steal them.
        guard terminal.lendingSurfaces else { return }
        let t = store.theme
        layer?.backgroundColor = t.win.cgColor
        let snap = makeSnapshot()
        let view = store.missionView
        let barH = z(36), statusH = z(24)
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        status.frame = NSRect(x: 0, y: bounds.height - statusH, width: bounds.width, height: statusH)
        var area = NSRect(x: 0, y: barH, width: bounds.width, height: max(0, bounds.height - barH - statusH))

        let attention = snap.tiles.filter { $0.activity == .attention }
        banner.isHidden = attention.isEmpty
        if !attention.isEmpty {
            banner.frame = NSRect(x: area.minX, y: area.minY, width: area.width, height: z(30))
            banner.update(tiles: attention, theme: t)
            area.origin.y += z(30)
            area.size.height -= z(30)
        }
        let trackerStyle = store.missionTracker
        tracker.isHidden = trackerStyle != .list
        if trackerStyle == .list {
            let width = min(z(280), area.width * 0.32)
            tracker.frame = NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
            tracker.update(snap: snap, selectedKey: selectedItemKey, repoKey: repoKey, detail: store.selectedItem, theme: t)
            area.size.width -= width
        }
        board.isHidden = trackerStyle != .board
        if trackerStyle == .board {
            let height = min(z(220), area.height * 0.4)
            board.frame = NSRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
            board.update(snap: snap, selectedKey: selectedItemKey, repoKey: repoKey, theme: t)
            area.size.height -= height
        }
        let hero = view == .focus ? MissionTilePolicy.focusAfterFilter(
            current: terminal.activePaneId?.uuidString, visible: snap.visible.map(\.id)).flatMap(UUID.init(uuidString:)) : nil
        cards.isHidden = view != .focus || snap.visible.count < 2
        if !cards.isHidden {
            let width = min(z(260), area.width * 0.3)
            cards.frame = NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
            cards.update(snap: snap, hero: hero, theme: t)
            area.size.width -= width
        }
        grid.frame = area.insetBy(dx: z(8), dy: z(8))
        let page = layoutTiles(snap, hero: hero, theme: t)

        let counts = MissionTilePolicy.counts(snap.tiles)
        let pageCount = MissionPagePolicy.pageCount(count: snap.visible.count, perPage: perPage)
        bar.update(MissionBarView.State(view: view, preset: store.missionLayout, resolved: resolvedPreset,
                                        filter: filter, counts: [counts.all, counts.working, counts.attention],
                                        page: page, pageCount: pageCount, cramped: crampedPresets(),
                                        repoTitle: repoKey,
                                        themeKey: t.key, scale: uiScale), theme: t)
        status.update(position: positionText(snap, page: page, pageCount: pageCount, hero: hero),
                      hints: view == .grid ? "⌃⌘←→ tile   ⌃⌘↑↓ page   ⌃⌘= − tiles   ⌃⌘T tracker   ⌃⌘M classic"
                                           : "⌃⌘←→ session   ⌃⌘1 grid   ⌃⌘T tracker   ⌃⌘M classic",
                      theme: t)
        ensureKeyboardFocus()
    }

    /// Fixed presets that would shrink terminals below the usable minimum in the current grid area.
    private func crampedPresets() -> Set<MissionLayoutPreset> {
        let area = grid.bounds.size, minimum = minimumTileSize
        return Set(MissionLayoutPreset.fixed.filter { preset in
            guard let s = preset.shape else { return false }
            return !MissionPagePolicy.fits(columns: s.columns, rows: s.rows, areaWidth: area.width, areaHeight: area.height,
                                           minTileWidth: minimum.width, minTileHeight: minimum.height,
                                           gap: z(MissionTileMetrics.forColumns(s.columns).gap))
        })
    }

    /// "Sessions 5–8 of 12 · page 2/3 · 2×2" — where you are, always visible.
    private func positionText(_ snap: MissionSnapshot, page: Int, pageCount: Int, hero: UUID?) -> String {
        let total = snap.visible.count
        let hidden = snap.tiles.count - total
        let suffix = hidden > 0 ? "  (\(hidden) hidden by filter)" : ""
        guard total > 0 else { return "No sessions match" + suffix }
        if let hero, let index = visibleOrder.firstIndex(of: hero) {
            return "Focus · session \(index + 1) of \(total)" + suffix
        }
        let range = MissionPagePolicy.range(page: page, perPage: perPage, count: total)
        let shown = range.count == 1 ? "Session \(range.lowerBound + 1)" : "Sessions \(range.lowerBound + 1)–\(range.upperBound)"
        let layout = store.missionLayout == .auto ? "auto \(resolvedPreset.title)" : resolvedPreset.title
        return "\(shown) of \(total) · page \(page + 1)/\(pageCount) · \(layout)" + suffix
    }

    private func makeSnapshot() -> MissionSnapshot {
        let panes = terminal.missionPanes
        let items = store.visiblePRs + store.visibleIssues
        let refs = items.map { MissionItemRef(repo: $0.repo, number: $0.number) }
        var links: [UUID: String] = [:]
        let domainTiles = panes.map { pane -> MissionTile in
            let link = SessionItemLink.resolve(manual: manualLinks[pane.id], title: pane.title, items: refs)
            links[pane.id] = link
            return MissionTile(id: pane.id.uuidString, title: pane.title,
                               activity: MissionTilePolicy.activity(busy: pane.busy != .idle, bell: pane.hasBell),
                               linkedItemKey: link, repoKey: link.flatMap(SessionItemLink.repo(ofKey:)))
        }
        var visible = MissionTilePolicy.visible(domainTiles, filter: filter, repoKey: repoKey)
        if store.missionGroupByRepo {
            visible = MissionTilePolicy.orderedByRepo(visible, repoOrder: store.allOrgRepos.map { "\($0.owner)/\($0.name)" })
        }
        let focusedTitle = terminal.activePaneId.flatMap { id in panes.first { $0.id == id }?.title }
        // A pane's `tint` is its connection's color, kept current by `syncConnectionTints`.
        let colors = Dictionary(panes.compactMap { pane in pane.tint.map { (pane.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        return MissionSnapshot(panes: panes, tiles: domainTiles, links: links, colors: colors, items: items,
                               visible: visible, focusedTitle: focusedTitle)
    }

    // MARK: Tiles

    /// Place the tiles for the current view and return the page shown.
    private func layoutTiles(_ snap: MissionSnapshot, hero: UUID?, theme t: Theme) -> Int {
        let live = Set(snap.panes.map(\.id))
        for (id, tile) in tiles where !live.contains(id) {   // pane closed; the dock freed its surface
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        visibleOrder = snap.visibleIds
        let area = grid.bounds.size

        let shape = MissionPagePolicy.shape(preset: store.missionLayout, count: visibleOrder.count,
                                            areaWidth: area.width, areaHeight: area.height,
                                            minTileWidth: minimumTileSize.width, minTileHeight: minimumTileSize.height,
                                            gap: z(MissionTileMetrics.forColumns(3).gap))
        resolvedPreset = shape.preset
        perPage = shape.perPage
        let page = currentPage
        lastPage = page

        let shown: [UUID]
        let frames: [UUID: NSRect]
        let metrics: MissionTileMetrics
        if let hero {
            shown = [hero]
            frames = [hero: NSRect(origin: .zero, size: area)]
            metrics = .forColumns(1)
        } else {
            shown = Array(visibleOrder[MissionPagePolicy.range(page: page, perPage: perPage, count: visibleOrder.count)])
            metrics = .forColumns(shape.columns)
            frames = pageFrames(shown, shape: shape, area: area, gap: z(metrics.gap))
        }
        layoutEmptySlots(hero == nil ? MissionPagePolicy.emptySlots(count: shown.count, shape: shape) : 0,
                         after: shown.count, shape: shape, area: area, gap: z(metrics.gap), theme: t)

        // Every live pane keeps a tile hosting its surface; ones not shown are parked hidden at their
        // last size (no resize → no terminal reflow).
        let shownSet = Set(shown)
        for pane in snap.panes {
            let tile = tiles[pane.id] ?? makeTile(pane.id)
            tile.host(pane.view)
            // The dragged tile stays visible across a spring-loaded page flip.
            if !shownSet.contains(pane.id), pane.id != drag?.pane, !tile.isHidden { tile.isHidden = true }
        }
        let focusedPane = terminal.activePaneId
        let tilesById = Dictionary(snap.visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in shown {
            guard let tile = tiles[id], let frame = frames[id], let domain = tilesById[id.uuidString] else { continue }
            let link = snap.links[id]
            tile.configure(MissionTileView.Content(
                title: domain.title, activity: domain.activity,
                linkLabel: link.map { "#" + ($0.split(separator: "#").last.map(String.init) ?? "") },
                repoLabel: store.missionGroupByRepo ? (domain.repoKey.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "unlinked") : nil,
                highlighted: link != nil && link == selectedItemKey,
                focused: id == focusedPane,
                dimmed: selectedItemKey != nil && link != selectedItemKey,
                color: snap.colors[id]),
                geometry: metrics, theme: t)
            // Grouping decides the order while it's on, so a reorder drag would appear to do nothing.
            tile.dragEnabled = hero == nil && !store.missionGroupByRepo
            // Unchanged frame → no surface resize. The dragged tile follows the cursor, not the grid.
            if id != drag?.pane, tile.frame != frame { tile.frame = frame }
            if tile.isHidden { tile.isHidden = false }
        }
        return page
    }

    /// Frames for one page: every slot has the preset's exact size (`MissionPagePolicy.slot`), the same
    /// on every page — so the grid matches its icon and a flip never resizes a terminal.
    private func pageFrames(_ ids: [UUID], shape: MissionPageShape, area: CGSize, gap: CGFloat) -> [UUID: NSRect] {
        var frames: [UUID: NSRect] = [:]
        for (index, id) in ids.enumerated() { frames[id] = slotFrame(index, shape: shape, area: area, gap: gap) }
        return frames
    }

    private func slotFrame(_ index: Int, shape: MissionPageShape, area: CGSize, gap: CGFloat) -> NSRect {
        let slot = MissionPagePolicy.slot(indexOnPage: index, shape: shape)
        let tileW = (area.width - gap * CGFloat(shape.columns - 1)) / CGFloat(shape.columns)
        let tileH = (area.height - gap * CGFloat(shape.rows - 1)) / CGFloat(shape.rows)
        return NSRect(x: CGFloat(slot.column) * (tileW + gap), y: CGFloat(slot.row) * (tileH + gap),
                      width: tileW, height: tileH).integral
    }

    /// Dashed "New session" placeholders in a page's empty slots — the grid keeps its shape, and the
    /// gap invites the obvious next action instead of looking broken.
    private func layoutEmptySlots(_ count: Int, after filled: Int, shape: MissionPageShape, area: CGSize,
                                  gap: CGFloat, theme t: Theme) {
        while emptySlots.count < count {
            let slot = MissionEmptySlotView()
            slot.onClick = { [weak self] in self?.terminal.openLocalTab() }
            grid.addSubview(slot, positioned: .below, relativeTo: nil)
            emptySlots.append(slot)
        }
        for (index, slot) in emptySlots.enumerated() {
            slot.isHidden = index >= count
            guard index < count else { continue }
            slot.frame = slotFrame(filled + index, shape: shape, area: area, gap: gap)
            slot.showsLabel = index == 0
            slot.apply(theme: t)
        }
    }

    private func makeTile(_ id: UUID) -> MissionTileView {
        let tile = MissionTileView(sessionId: id)
        tile.onFocus = { [weak self] in self?.focusTile(id) }
        tile.onClose = { [weak self] in self?.terminal.requestCloseLentPane(id) }
        tile.onDragBegin = { [weak self] event in self?.beginDrag(id, event) }
        tile.onDragMove = { [weak self] event in self?.moveDrag(id, event) }
        tile.onDragEnd = { [weak self] in self?.endDrag(id) }
        grid.addSubview(tile)
        tiles[id] = tile
        return tile
    }

    /// The smallest tile Auto accepts: a 64×16-cell terminal at the configured terminal font, plus the
    /// header. Fixed presets ignore it — what the user picks is what they get.
    private var minimumTileSize: CGSize {
        let size = CGFloat(terminalConfig.fontSize) * uiScale
        let font = NSFont(name: terminalConfig.fontFamily, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cellW = ("M" as NSString).size(withAttributes: [.font: font]).width
        let cellH = ceil(font.ascender - font.descender + font.leading)
        let padX = CGFloat(terminalConfig.paddingX) * 2, padY = CGFloat(terminalConfig.paddingY) * 2
        return CGSize(width: 64 * cellW + padX, height: 16 * cellH + padY + z(24))
    }

    // MARK: Drag to reorder

    /// Lift the tile: draw it above the others, slightly translucent, and remember where it was grabbed
    /// so it stays under the cursor. Moving only its origin never resizes the terminal.
    private func beginDrag(_ id: UUID, _ event: NSEvent) {
        guard let tile = tiles[id] else { return }
        let point = grid.convert(event.locationInWindow, from: nil)
        drag = (id, NSPoint(x: point.x - tile.frame.minX, y: point.y - tile.frame.minY))
        tile.layer?.zPosition = 10
        tile.layer?.opacity = 0.85
    }

    /// Follow the cursor and outline the tile it's over.
    private func moveDrag(_ id: UUID, _ event: NSEvent) {
        guard let drag, drag.pane == id, let tile = tiles[id] else { return }
        let point = grid.convert(event.locationInWindow, from: nil)
        tile.setFrameOrigin(NSPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y))
        armSpringFlip(bar.pageArrow(at: bar.convert(event.locationInWindow, from: nil)))
        let target = visibleOrder.first { other in
            other != id && (tiles[other].map { !$0.isHidden && $0.frame.contains(point) } ?? false)
        }
        guard target != dropTarget else { return }
        dropTarget.flatMap { tiles[$0] }?.isDropTarget = false
        target.flatMap { tiles[$0] }?.isDropTarget = true
        dropTarget = target
    }

    /// Hovering a pager arrow mid-drag flips the page after 0.6 s (and keeps flipping while held), so a
    /// tile can be carried to another page and dropped on a tile there. Leaving the arrow cancels it.
    private func armSpringFlip(_ direction: Int?) {
        guard direction != springDirection else { return }
        springFlip?.cancel()
        springFlip = nil
        springDirection = direction
        bar.highlightArrow(direction)
        guard let direction else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag != nil, self.springDirection == direction else { return }
            self.flipPageKeepingDrag(direction)
            self.springDirection = nil          // re-arm so holding the cursor there flips again
            self.armSpringFlip(direction)
        }
        springFlip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Flip the page during a drag: focus the new page's first tile that isn't the one being carried.
    private func flipPageKeepingDrag(_ delta: Int) {
        let target = MissionPagePolicy.clampPage(currentPage + delta, count: visibleOrder.count, perPage: perPage)
        let range = MissionPagePolicy.range(page: target, perPage: perPage, count: visibleOrder.count)
        guard target != currentPage, let first = range.map({ visibleOrder[$0] }).first(where: { $0 != drag?.pane })
        else { return }
        focusTile(first)
        layoutSubtreeIfNeeded()
    }

    /// Drop: move the dragged session's tab into the target's slot (the dock re-tiles on the change);
    /// with no target the tile just settles back into the grid.
    private func endDrag(_ id: UUID) {
        springFlip?.cancel()
        springFlip = nil
        springDirection = nil
        bar.highlightArrow(nil)
        if let tile = tiles[id] {
            tile.layer?.zPosition = 0
            tile.layer?.opacity = 1
        }
        dropTarget.flatMap { tiles[$0] }?.isDropTarget = false
        let target = dropTarget
        dropTarget = nil
        drag = nil
        if let target {
            terminal.moveTab(ofPane: id, toSlotOfPane: target)
            // Follow the tile: focus it so the page shown is the one it landed on.
            DispatchQueue.main.async { [weak self] in self?.focusTile(id) }
        }
        needsLayout = true
    }

    // MARK: Keyboard focus

    /// Keep the keyboard on a shown tile: if the active pane is filtered out, move focus to the first
    /// visible tile; if focus fell to the window (a tile was hidden or removed under it), put it back on
    /// the active pane. Never steals focus from a text field or another view.
    private func ensureKeyboardFocus() {
        guard let window else { return }
        let active = terminal.activePaneId
        if let active, !visibleOrder.contains(active) {
            guard let first = visibleOrder.first else { return }
            DispatchQueue.main.async { [weak self] in self?.focusTile(first) }
            return
        }
        let responder = window.firstResponder
        if responder == nil || responder === window, let active {
            DispatchQueue.main.async { [weak self] in self?.focusTile(active) }
        }
    }
}
