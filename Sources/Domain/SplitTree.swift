import Foundation

/// A recursive **binary** split tree describing how one terminal tab is divided into live panes
/// (#68). A `.leaf` is a single pane (its surface id); a `.split` divides a region into two children
/// along an axis, with `fraction` the **first** child's share of the parent extent. libghostty has no
/// native split, so the App layer hosts one surface per leaf and uses `frames`/`dividers` here to
/// size them and place the resize grips. Kept pure (`Double` / `SplitRect`, no CoreGraphics) and
/// unit-tested, so the same tree drives layout, focus navigation, and persistence. Reuses
/// `SplitLayout`'s clamps so a pane can't be dragged below its floor — the side-by-side *width* floor
/// (`minPane`) for a `.horizontal` split, the stacked *height* floor (`minTerminalHeight`) for a
/// `.vertical` one. The generic leaf id is the live surface `UUID` in the App layer and a persisted
/// `TerminalTabState` in `Preferences.openTabTrees`.
public indirect enum SplitNode<ID: Equatable> {
    /// One pane, identified by its surface/leaf id.
    case leaf(ID)
    /// A region divided in two along `axis` (`.horizontal` = side by side, `first` left; `.vertical`
    /// = stacked, `first` on top). `fraction` ∈ [0, 1] is the first child's share of the space left
    /// after the divider gap.
    case split(axis: SplitAxis, fraction: Double, first: SplitNode<ID>, second: SplitNode<ID>)
}

extension SplitNode: Equatable {}
extension SplitNode: Sendable where ID: Sendable {}
extension SplitNode: Codable where ID: Codable {}

/// Which way `focusNeighbor` steps through the leaves (the ⌘] / ⌘[ focus-move actions).
public enum PaneFocusDirection: Sendable {
    case previous, next
}

/// A divider seam produced by `dividers`, enough for the App layer to host one resize grip per
/// internal split. `path` addresses the split node (see `setFraction`); `rect` is the seam strip
/// (divider-thick, straddled by a fat hit-zone in the view); `axis` is the split's orientation; and
/// `extent` is the span along the axis (parent extent minus the divider) used to turn a drag in
/// points into a change in `fraction`.
public struct SplitDivider: Equatable, Sendable {
    public var path: [Int]
    public var rect: SplitRect
    public var axis: SplitAxis
    public var extent: Double

    public init(path: [Int], rect: SplitRect, axis: SplitAxis, extent: Double) {
        self.path = path
        self.rect = rect
        self.axis = axis
        self.extent = extent
    }
}

/// A rectangle in `Double`, mirroring `SettingsPaneLayout.Frame`: Domain geometry that the App layer
/// converts to `CGRect` at the boundary, keeping CoreGraphics out of Domain.
public struct SplitRect: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var width: Double
    public var height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

extension SplitNode {

    // MARK: Leaves

    /// Every pane id, in depth-first first-then-second order — the order panes read left-to-right /
    /// top-to-bottom, and the order `mapLeaves` visits them.
    public var leafIDs: [ID] {
        switch self {
        case .leaf(let id): return [id]
        case let .split(_, _, first, second): return first.leafIDs + second.leafIDs
        }
    }

    /// The first (leading) pane — the focus fallback when a saved focused pane is gone.
    public var firstLeaf: ID {
        switch self {
        case .leaf(let id): return id
        case let .split(_, _, first, _): return first.firstLeaf
        }
    }

    /// How many panes the tree holds. `> 1` means the tab is actually split (draws dividers + a focus
    /// ring); `== 1` is a plain single-pane tab, byte-for-byte the pre-#68 behavior.
    public var leafCount: Int {
        switch self {
        case .leaf: return 1
        case let .split(_, _, first, second): return first.leafCount + second.leafCount
        }
    }

    public func contains(_ id: ID) -> Bool { leafIDs.contains(id) }

    // MARK: Mutation

    /// Split the pane `focused` into two, replacing it with an even `.split` of the existing pane and
    /// `newLeaf`. `newLeafTrailing` puts the new pane second (right/bottom — the ⌘D / ⇧⌘D default);
    /// `false` puts it first. An unknown `focused` leaves the tree unchanged.
    public func insertSplit(focused: ID, axis: SplitAxis, newLeaf: ID, newLeafTrailing: Bool = true) -> SplitNode {
        switch self {
        case .leaf(let id):
            guard id == focused else { return self }
            let existing = SplitNode.leaf(id)
            let added = SplitNode.leaf(newLeaf)
            let pair = newLeafTrailing ? (existing, added) : (added, existing)
            return .split(axis: axis, fraction: 0.5, first: pair.0, second: pair.1)
        case let .split(nodeAxis, fraction, first, second):
            // Recurse with the *requested* axis (not this node's), so a split deep down adopts the
            // axis the user asked for.
            return .split(axis: nodeAxis, fraction: fraction,
                          first: first.insertSplit(focused: focused, axis: axis, newLeaf: newLeaf, newLeafTrailing: newLeafTrailing),
                          second: second.insertSplit(focused: focused, axis: axis, newLeaf: newLeaf, newLeafTrailing: newLeafTrailing))
        }
    }

    /// Remove the pane `id`, collapsing its lone sibling up into the parent's slot (so the sibling
    /// reclaims the freed space). `nil` when the whole tree was a single leaf that got removed; an
    /// unknown `id` leaves the tree unchanged.
    public func remove(_ id: ID) -> SplitNode? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self
        case let .split(axis, fraction, first, second):
            switch (first.remove(id), second.remove(id)) {
            case (nil, nil): return nil                                   // unreachable for unique ids
            case (nil, let survivor?), (let survivor?, nil): return survivor
            case let (newFirst?, newSecond?):
                return .split(axis: axis, fraction: fraction, first: newFirst, second: newSecond)
            }
        }
    }

    /// The pane to focus when moving `direction` from `id`, cycling through `leafIDs` and wrapping at
    /// the ends. `nil` for a single-pane tree or an unknown id (a no-op). Mirrors
    /// `TerminalTabs.target(for:)`'s modular prev/next.
    public func focusNeighbor(of id: ID, _ direction: PaneFocusDirection) -> ID? {
        let ids = leafIDs
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return nil }
        let count = ids.count
        switch direction {
        case .next: return ids[(index + 1) % count]
        case .previous: return ids[(index - 1 + count) % count]
        }
    }

    // MARK: Geometry

    /// Each pane's rectangle within `rect`, recursively, reserving a `divider`-thick gap at every
    /// seam (so `child + divider + child == parent` along the split axis) and clamping each split's
    /// fraction with `SplitLayout` so neither child drops below its axis floor.
    public func frames(in rect: SplitRect, divider: Double) -> [(ID, SplitRect)] {
        switch self {
        case .leaf(let id):
            return [(id, rect)]
        case let .split(axis, fraction, first, second):
            let (firstRect, secondRect) = Self.childRects(rect: rect, axis: axis, fraction: fraction, divider: divider)
            return first.frames(in: firstRect, divider: divider) + second.frames(in: secondRect, divider: divider)
        }
    }

    /// One `SplitDivider` per internal split, addressed by `path` (the child indices from the root,
    /// `0` = first, `1` = second). The view hosts a resize grip per divider; dragging it feeds
    /// `setFraction(at: path, …)`.
    public func dividers(in rect: SplitRect, divider thickness: Double) -> [SplitDivider] {
        Self.dividers(of: self, in: rect, thickness: thickness, path: [])
    }

    private static func dividers(of node: SplitNode, in rect: SplitRect, thickness: Double, path: [Int]) -> [SplitDivider] {
        guard case let .split(axis, fraction, first, second) = node else { return [] }
        let (firstRect, secondRect) = childRects(rect: rect, axis: axis, fraction: fraction, divider: thickness)
        let seam: SplitRect
        let extent: Double
        switch axis {
        case .horizontal:
            seam = SplitRect(minX: firstRect.minX + firstRect.width, minY: rect.minY, width: thickness, height: rect.height)
            extent = max(0, rect.width - thickness)
        case .vertical:
            seam = SplitRect(minX: rect.minX, minY: firstRect.minY + firstRect.height, width: rect.width, height: thickness)
            extent = max(0, rect.height - thickness)
        }
        return [SplitDivider(path: path, rect: seam, axis: axis, extent: extent)]
            + dividers(of: first, in: firstRect, thickness: thickness, path: path + [0])
            + dividers(of: second, in: secondRect, thickness: thickness, path: path + [1])
    }

    /// The two child rects of a split: divide `rect` along `axis`, reserving the divider gap and
    /// clamping the first child's `fraction` so both children honor the axis floor (`minPane` for a
    /// side-by-side `.horizontal` split, `minTerminalHeight` for a stacked `.vertical` one).
    private static func childRects(rect: SplitRect, axis: SplitAxis, fraction: Double, divider: Double) -> (SplitRect, SplitRect) {
        switch axis {
        case .horizontal:
            let available = max(0, rect.width - divider)
            let firstWidth = available * SplitLayout.clampFraction(fraction, total: available, minPane: SplitLayout.minPane)
            let secondWidth = max(0, available - firstWidth)
            return (SplitRect(minX: rect.minX, minY: rect.minY, width: firstWidth, height: rect.height),
                    SplitRect(minX: rect.minX + firstWidth + divider, minY: rect.minY, width: secondWidth, height: rect.height))
        case .vertical:
            let available = max(0, rect.height - divider)
            let firstHeight = available * SplitLayout.clampFraction(fraction, total: available, minPane: SplitLayout.minTerminalHeight)
            let secondHeight = max(0, available - firstHeight)
            return (SplitRect(minX: rect.minX, minY: rect.minY, width: rect.width, height: firstHeight),
                    SplitRect(minX: rect.minX, minY: rect.minY + firstHeight + divider, width: rect.width, height: secondHeight))
        }
    }

    /// The `fraction` stored at the split addressed by `path` (a divider's `path`), or `nil` if the
    /// path doesn't land on a split. The read twin of `setFraction` — the drag captures it on begin.
    public func fraction(at path: [Int]) -> Double? {
        guard case let .split(_, fraction, first, second) = self else { return nil }
        guard let step = path.first else { return fraction }
        let rest = Array(path.dropFirst())
        switch step {
        case 0: return first.fraction(at: rest)
        case 1: return second.fraction(at: rest)
        default: return nil
        }
    }

    /// Set the `fraction` of the split addressed by `path` (the divider's `path`), clamped to
    /// `[0, 1]`; `frames` re-applies the axis floor at render time. A path that runs into a leaf (or
    /// off the tree) leaves it unchanged.
    public func setFraction(at path: [Int], to fraction: Double) -> SplitNode {
        guard case let .split(axis, current, first, second) = self else { return self }
        guard let step = path.first else {
            return .split(axis: axis, fraction: min(1, max(0, fraction)), first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        switch step {
        case 0: return .split(axis: axis, fraction: current, first: first.setFraction(at: rest, to: fraction), second: second)
        case 1: return .split(axis: axis, fraction: current, first: first, second: second.setFraction(at: rest, to: fraction))
        default: return self
        }
    }

    // MARK: Transform (persistence re-key / prune)

    /// A tree of the same shape with each pane id mapped through `transform`, visited in `leafIDs`
    /// order. Used on snapshot (live surface id → persisted `TerminalTabState`) and restore
    /// (persisted leaf → fresh surface id, or `nil` for a deleted connection — see `compacted`).
    public func mapLeaves<T: Equatable>(_ transform: (ID) -> T) -> SplitNode<T> {
        switch self {
        case .leaf(let id):
            return .leaf(transform(id))
        case let .split(axis, fraction, first, second):
            return .split(axis: axis, fraction: fraction,
                          first: first.mapLeaves(transform), second: second.mapLeaves(transform))
        }
    }
}

extension SplitNode {
    /// Drop every leaf whose payload is `nil`, collapsing as `remove` does; `nil` if nothing
    /// survives. Pairs with `mapLeaves` on restore: map each persisted leaf to its rebuilt surface id
    /// (`nil` when its connection was deleted), then `compacted()` prunes the gone panes.
    public func compacted<Wrapped>() -> SplitNode<Wrapped>? where ID == Wrapped? {
        switch self {
        case .leaf(let value):
            return value.map { SplitNode<Wrapped>.leaf($0) }
        case let .split(axis, fraction, first, second):
            switch (first.compacted(), second.compacted()) {
            case (nil, nil): return nil
            case (let survivor?, nil), (nil, let survivor?): return survivor
            case let (newFirst?, newSecond?):
                return .split(axis: axis, fraction: fraction, first: newFirst, second: newSecond)
            }
        }
    }
}
