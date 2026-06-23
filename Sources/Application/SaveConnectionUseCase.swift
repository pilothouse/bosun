import Domain
import Foundation

/// Validates a connection draft against the Domain rule and, if it passes, persists it.
/// One collaborator (the store) — the validation rule itself stays pure in Domain.
public struct SaveConnectionUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    /// `.saved` once persisted; `.invalid` carries the field errors so the form can render them.
    public enum Outcome: Sendable, Equatable {
        case saved(Connection)
        case invalid([ConnectionValidationError])
    }

    public func callAsFunction(_ draft: ConnectionDraft) async throws -> Outcome {
        let errors = ConnectionPolicy.validate(draft)
        guard errors.isEmpty else { return .invalid(errors) }

        let trimmedCustom = draft.customCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = Connection(
            id: draft.id ?? UUID(),
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: draft.kind,
            isFavorite: draft.isFavorite,
            customCommand: (trimmedCustom?.isEmpty == false) ? trimmedCustom : nil
        )
        try await store.save(connection)
        return .saved(connection)
    }
}
