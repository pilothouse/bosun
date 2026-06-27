import Domain
import Foundation

/// Moves a connection into a folder (or out of all folders, with `folderId == nil` → Ungrouped) and
/// persists it. One collaborator (the store): read the connection, retarget its `folderId`, save.
/// Thin — the move carries no rule beyond setting the field — but routing it through a use case
/// keeps the rail off the concrete store, and makes "move" a single seam the drag and the
/// context-menu both call. A no-op move (already in the target folder) writes nothing.
public struct MoveConnectionToFolderUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    public func callAsFunction(connectionId: UUID, folderId: UUID?) async throws {
        guard var connection = try await store.all().first(where: { $0.id == connectionId }),
              connection.folderId != folderId else { return }
        connection.folderId = folderId
        try await store.save(connection)
    }
}
