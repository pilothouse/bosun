/// The pure diff behind incremental refresh. Given the freshly-fetched list (`incoming`) and the
/// last-known one (`existing`), it reports which rows are new-or-changed and which are gone — keyed
/// by `id`, with "changed" meaning "no longer `==`" (the GitHub value types are already `Equatable`,
/// and there's no `updatedAt`, so equality is full-value). This is the kind of `if` Domain owns, so
/// both the menu-bar refresh and any future sweep share one definition instead of drifting copies.
///
/// `merged` is the resolved set — `incoming` order and values, i.e. insert/update/remove already
/// applied. v1 writes `merged` into the store and uses `isUnchanged` to skip a redundant view
/// rebuild on a no-op refresh; `changedIDs`/`removedIDs` are what a later per-row renderer re-lays.
public enum GitHubDelta {
    public struct Outcome<Element: Identifiable> {
        /// `incoming` with insert/update/remove applied (== `incoming` in order and value).
        public let merged: [Element]
        /// Ids present in `incoming` that are new, or whose value differs from `existing`.
        public let changedIDs: Set<Element.ID>
        /// Ids that were in `existing` but are absent from `incoming`.
        public let removedIDs: Set<Element.ID>
        /// No row was added, changed, or removed — a pure-noise refresh the UI can ignore.
        public var isUnchanged: Bool { changedIDs.isEmpty && removedIDs.isEmpty }
    }

    public static func apply<Element>(incoming: [Element], to existing: [Element])
        -> Outcome<Element> where Element: Identifiable & Equatable, Element.ID: Hashable {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changedIDs = Set<Element.ID>()
        for element in incoming {
            guard let previous = existingByID[element.id] else {
                changedIDs.insert(element.id)   // not seen before → new
                continue
            }
            if previous != element { changedIDs.insert(element.id) }   // same id, different value
        }
        let incomingIDs = Set(incoming.map(\.id))
        let removedIDs = Set(existingByID.keys).subtracting(incomingIDs)
        return Outcome(merged: incoming, changedIDs: changedIDs, removedIDs: removedIDs)
    }
}
