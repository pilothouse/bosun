import Foundation

/// Removes a saved connection by id. Thin by design — deletion carries no business rule,
/// but routing it through a use case keeps views off the concrete store.
public struct RemoveConnectionUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    public func callAsFunction(id: UUID) async throws {
        try await store.delete(id: id)
    }
}
