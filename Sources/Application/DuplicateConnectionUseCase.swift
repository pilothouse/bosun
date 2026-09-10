import Domain
import Foundation

/// Duplicates a saved connection (#101): a complete copy under a fresh id, named by the Domain rule,
/// persisted directly below its original. One collaborator (the store) — it owns the orchestration
/// (read the list, apply the pure rules, write) while the meaning of "what a copy is called" and
/// "where it goes" stays in `ConnectionNaming` / `ConnectionOrdering`.
///
/// There is nothing hidden to carry across: a `Connection` holds no secret (SSH auth is delegated to
/// `ssh-agent`), so copying its fields reproduces it completely. Both writes go through the port, so
/// the iCloud decorator stamps and pushes the copy exactly as it would a hand-made connection.
public struct DuplicateConnectionUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    /// `.duplicated` carries the new connection so the rail can place and select it; `.notFound` is a
    /// row that vanished between the click and the read — nothing is written.
    public enum Outcome: Sendable, Equatable {
        case duplicated(Connection)
        case notFound
    }

    public func callAsFunction(id: UUID) async throws -> Outcome {
        let all = try await store.all()
        guard let source = all.first(where: { $0.id == id }) else { return .notFound }

        let copy = Connection(
            id: UUID(),
            name: ConnectionNaming.copyName(of: source.name, existing: all.map(\.name)),
            kind: source.kind,
            isFavorite: source.isFavorite,
            customCommand: source.customCommand,
            folderId: source.folderId
        )
        // `save` appends, so the copy would land at the bottom of its section; the reorder puts it
        // back under the row it was copied from.
        try await store.save(copy)
        try await store.reorder(ConnectionOrdering.inserting(copy.id, after: source.id,
                                                             in: all.map(\.id) + [copy.id]))
        return .duplicated(copy)
    }
}
