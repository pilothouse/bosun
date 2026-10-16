import Domain
import Foundation

/// Sets (or, with `color == nil`, clears) a connection's color and persists it — the rail's quick
/// "Color ▸" change (#102). One collaborator (the store): read the connection, set its `color`, save.
/// Thin like `MoveConnectionToFolderUseCase`, whose shape it copies — routing the change through a use
/// case keeps the rail off the concrete store. A no-op (same color, or a vanished row) writes nothing,
/// so it never bumps `updatedAt` or pushes to iCloud for nothing.
public struct SetConnectionColorUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    public func callAsFunction(connectionId: UUID, color: ConnectionColor?) async throws {
        guard var connection = try await store.all().first(where: { $0.id == connectionId }),
              connection.color != color else { return }
        connection.color = color
        try await store.save(connection)
    }
}
