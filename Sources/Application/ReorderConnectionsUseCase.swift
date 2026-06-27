import Domain
import Foundation

/// Reorders saved connections within one rail section and persists the new order. Parallel to
/// `SaveConnectionUseCase` (one collaborator, the store): it owns the orchestration — read the
/// full list, apply the pure `ConnectionOrdering` rule, write the result — while the meaning of
/// the move stays in Domain.
public struct ReorderConnectionsUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    /// Move the connection at `from` to `to` inside the section listed (in display order) by
    /// `sectionIDs`, leaving every other connection fixed, then persist. A move that changes
    /// nothing (`from == to`, out of range) writes nothing.
    public func callAsFunction(sectionIDs: [UUID], from: Int, to: Int) async throws {
        let current = try await store.all().map(\.id)
        let next = ConnectionOrdering.reorder(current, sectionIDs: sectionIDs, from: from, to: to)
        guard next != current else { return }
        try await store.reorder(next)
    }
}
