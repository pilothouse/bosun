import Domain
import Foundation

/// Deletes a folder *and every connection inside it* (a cascade — the user is warned by a confirm
/// dialog in the App layer first). One collaborator (the store): read the connections, delete the
/// members, then drop the folder record. The cascade carries a rule — "which connections go with
/// the folder" — but it's a plain filter on `folderId`, so it lives here rather than needing its
/// own Domain function. Returns the count of connections removed, so the caller can reconcile a
/// dangling selection.
public struct RemoveFolderUseCase: Sendable {
    private let store: ConnectionStore

    public init(store: ConnectionStore) {
        self.store = store
    }

    @discardableResult
    public func callAsFunction(id: UUID) async throws -> Int {
        let members = try await store.all().filter { $0.folderId == id }
        for member in members {
            try await store.delete(id: member.id)
        }
        try await store.deleteFolder(id: id)
        return members.count
    }
}
