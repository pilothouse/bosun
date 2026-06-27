import Domain
import Foundation

/// Reorders the user folders and persists the new order. Parallel to `ReorderConnectionsUseCase`
/// (one collaborator, the store): it owns the orchestration — read the folders, apply the pure
/// `FolderOrdering` rule, write the result — while the meaning of the move stays in Domain. A move
/// that changes nothing (`from == to`, out of range) writes nothing.
public struct ReorderFoldersUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    public func callAsFunction(from: Int, to: Int) async throws {
        let current = try await store.folders().map(\.id)
        let next = FolderOrdering.reorder(current, from: from, to: to)
        guard next != current else { return }
        try await store.reorderFolders(next)
    }
}
