import Foundation

/// Flattens a parent/child relationship over a list of items into the ordered, indented rows the
/// panel renders for "By parent" / "By blocked-by". Pure and generic over the item id, so it runs
/// the same whether the key is a sub-issue parent or a blocker — and is unit-tested without a view.
///
/// This logic used to live inline in the panel and was the cause of issue #47 (it only nested one
/// level, ignored the active mode, and dropped items whose related item was filtered out). It's a
/// rule with branches, so per the architecture it belongs here in Domain where both the test and
/// the view share one definition.
public enum GitHubItemTree {
    /// One rendered line: the item's id, its indentation `depth` (0 = root), and whether it has any
    /// children in view (so the panel can draw an expand/collapse caret even while collapsed).
    public struct Row<ID: Hashable>: Equatable {
        public let id: ID
        public let depth: Int
        public let hasChildren: Bool

        public init(id: ID, depth: Int, hasChildren: Bool) {
            self.id = id
            self.depth = depth
            self.hasChildren = hasChildren
        }
    }

    /// Build the indented rows for `order` (the items in display order), nesting each item under
    /// `parentOf[id]`.
    ///
    /// - A relationship is honored only when the parent is also in `order` — an item whose parent is
    ///   absent (filtered out, or in another repo) is shown as a root, never dropped. A self-parent
    ///   is treated as no parent.
    /// - Roots and siblings keep `order`'s sequence.
    /// - Descendants of a `collapsed` id are omitted; the collapsed node itself stays, with
    ///   `hasChildren == true` so its caret remains.
    /// - Cycles can't loop: each item is emitted at most once, and a node only reachable through a
    ///   cycle is promoted to a root (in `order`) so nothing vanishes.
    public static func rows<ID: Hashable>(
        order: [ID], parentOf: [ID: ID], collapsed: Set<ID> = []) -> [Row<ID>] {
        let present = Set(order)
        var children: [ID: [ID]] = [:]
        var hasParent = Set<ID>()
        for id in order {
            if let parent = parentOf[id], parent != id, present.contains(parent) {
                children[parent, default: []].append(id)
                hasParent.insert(id)
            }
        }

        var result: [Row<ID>] = []
        var placed = Set<ID>()   // every node assigned a spot — emitted or hidden under a collapse
        func place(_ id: ID, depth: Int, hidden: Bool) {
            guard !placed.contains(id) else { return }   // cycle / re-entry guard
            placed.insert(id)
            let kids = children[id] ?? []
            if !hidden { result.append(Row(id: id, depth: depth, hasChildren: !kids.isEmpty)) }
            let childrenHidden = hidden || collapsed.contains(id)
            for child in kids { place(child, depth: depth + 1, hidden: childrenHidden) }
        }

        // Roots first (in order), then promote anything still unplaced — items reachable only
        // through a cycle — so the whole list always renders. Descendants hidden under a collapsed
        // ancestor are already `placed`, so they're never mistaken for cycle roots.
        for id in order where !hasParent.contains(id) { place(id, depth: 0, hidden: false) }
        for id in order where !placed.contains(id) { place(id, depth: 0, hidden: false) }
        return result
    }
}
