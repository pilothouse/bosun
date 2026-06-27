import Domain
import Foundation

/// Validates a folder draft against the Domain rule and, if it passes, persists it. One collaborator
/// (the store) — the validation rule itself stays pure in Domain. Mirrors `SaveConnectionUseCase`.
public struct SaveFolderUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    /// `.saved` once persisted; `.invalid` carries the field errors so the rail can render them.
    public enum Outcome: Sendable, Equatable {
        case saved(Folder)
        case invalid([FolderValidationError])
    }

    public func callAsFunction(_ draft: FolderDraft) async throws -> Outcome {
        let errors = FolderPolicy.validate(name: draft.name)
        guard errors.isEmpty else { return .invalid(errors) }

        let folder = Folder(id: draft.id ?? UUID(),
                            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
        try await store.saveFolder(folder)
        return .saved(folder)
    }
}
