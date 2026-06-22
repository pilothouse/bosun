import Foundation

/// Where a tab jump lands. `index` is 1-based to match ghostty's ⌘1…⌘9 bindings; the sentinels
/// mirror its previous/next/last navigation.
public enum TabJump: Sendable, Equatable {
    case previous
    case next
    case last
    case index(Int)
}

/// Pure ordered-tabs + active-selection model for the terminal dock. Holds tab identities in
/// display order and which one is active; every "which tab is active now?" decision — after a
/// close, a jump, or opening a tab — lives here so it is unit-tested away from AppKit and shared
/// by every trigger alike: the `+` button, a tab click, or a native ghostty keybinding.
public struct TerminalTabs<ID: Hashable>: Equatable {
    public private(set) var ids: [ID]
    public private(set) var activeID: ID?

    public init() {
        ids = []
        activeID = nil
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public var activeIndex: Int? { activeID.flatMap { ids.firstIndex(of: $0) } }

    /// Append a new tab (unless already present) and make it active.
    public mutating func open(_ id: ID) {
        if !ids.contains(id) { ids.append(id) }
        activeID = id
    }

    /// Make `id` active if it exists; otherwise a no-op.
    public mutating func select(_ id: ID) {
        guard ids.contains(id) else { return }
        activeID = id
    }

    /// Remove `id`. When the active tab is the one closed, the tab that shifts into its slot
    /// becomes active (or the new last tab when the final slot is closed); active is nil once the
    /// strip is empty. Returns the resulting active id.
    @discardableResult
    public mutating func close(_ id: ID) -> ID? {
        guard let idx = ids.firstIndex(of: id) else { return activeID }
        ids.remove(at: idx)
        if activeID == id {
            activeID = ids.isEmpty ? nil : ids[min(idx, ids.count - 1)]
        }
        return activeID
    }

    /// The id a jump would land on without mutating state (nil when there are no tabs, or an
    /// out-of-range index).
    public func target(for jump: TabJump) -> ID? {
        guard !ids.isEmpty else { return nil }
        switch jump {
        case .previous:
            guard let cur = activeIndex else { return ids.first }
            return ids[(cur - 1 + ids.count) % ids.count]
        case .next:
            guard let cur = activeIndex else { return ids.first }
            return ids[(cur + 1) % ids.count]
        case .last:
            return ids.last
        case .index(let oneBased):
            let zero = oneBased - 1
            return ids.indices.contains(zero) ? ids[zero] : nil
        }
    }

    /// Apply a jump, making its target active. A jump with no resolvable target is a no-op.
    public mutating func goto(_ jump: TabJump) {
        if let id = target(for: jump) { activeID = id }
    }
}
