import XCTest
import Domain
@testable import Application

/// A single in-memory `ConnectionStore` fake covering both collections (connections + folders), so
/// the folder use-case contract tests run against a fake instead of the disk. Mirrors the per-file
/// fakes in `SaveConnectionUseCaseTests` / `ReorderConnectionsUseCaseTests`, extended with the
/// folder side of the port.
private actor FakeStore: ConnectionStore {
    private(set) var connections: [Connection]
    private(set) var folderList: [Folder]
    private(set) var reorderFoldersCalls = 0

    init(connections: [Connection] = [], folders: [Folder] = []) {
        self.connections = connections
        self.folderList = folders
    }

    func all() -> [Connection] { connections }
    func save(_ connection: Connection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
    }
    func delete(id: UUID) { connections.removeAll { $0.id == id } }
    func reorder(_ orderedIDs: [UUID]) {
        connections.sort { a, b in
            (orderedIDs.firstIndex(of: a.id) ?? .max) < (orderedIDs.firstIndex(of: b.id) ?? .max)
        }
    }

    func folders() -> [Folder] { folderList }
    func saveFolder(_ folder: Folder) {
        if let idx = folderList.firstIndex(where: { $0.id == folder.id }) {
            folderList[idx] = folder
        } else {
            folderList.append(folder)
        }
    }
    func deleteFolder(id: UUID) { folderList.removeAll { $0.id == id } }
    func reorderFolders(_ orderedIDs: [UUID]) {
        reorderFoldersCalls += 1
        folderList.sort { a, b in
            (orderedIDs.firstIndex(of: a.id) ?? .max) < (orderedIDs.firstIndex(of: b.id) ?? .max)
        }
    }
}

private func ssh(_ name: String, folder: UUID? = nil) -> Connection {
    Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil), folderId: folder)
}

/// Validate → trim → persist, mirroring `SaveConnectionUseCaseTests`.
final class SaveFolderUseCaseTests: XCTestCase {
    func testValidNewDraftIsSavedWithFreshID() async throws {
        let store = FakeStore()
        let save = SaveFolderUseCase(store: store)

        let outcome = try await save(FolderDraft(id: nil, name: "  Project Acme  "))

        guard case let .saved(folder) = outcome else { return XCTFail("expected .saved") }
        XCTAssertEqual(folder.name, "Project Acme", "name is trimmed on save")
        let stored = await store.folders()
        XCTAssertEqual(stored.map(\.id), [folder.id])
    }

    func testEmptyDraftIsInvalidAndPersistsNothing() async throws {
        let store = FakeStore()
        let save = SaveFolderUseCase(store: store)

        let outcome = try await save(FolderDraft(id: nil, name: "   "))

        XCTAssertEqual(outcome, .invalid([.emptyName]))
        let stored = await store.folders()
        XCTAssertTrue(stored.isEmpty)
    }

    func testNonNilIDRenamesInPlace() async throws {
        let existing = Folder(id: UUID(), name: "old")
        let store = FakeStore(folders: [existing])
        let save = SaveFolderUseCase(store: store)

        _ = try await save(FolderDraft(id: existing.id, name: "new"))

        let stored = await store.folders()
        XCTAssertEqual(stored.count, 1, "an edit upserts, not appends")
        XCTAssertEqual(stored.first?.id, existing.id)
        XCTAssertEqual(stored.first?.name, "new")
    }
}

/// Cascade delete: the folder and every connection inside it go; non-members stay.
final class RemoveFolderUseCaseTests: XCTestCase {
    func testDeletesTheFolderAndItsMemberConnections() async throws {
        let folder = Folder(id: UUID(), name: "f")
        let inA = ssh("inA", folder: folder.id), inB = ssh("inB", folder: folder.id)
        let outside = ssh("outside")
        let store = FakeStore(connections: [inA, outside, inB], folders: [folder])
        let remove = RemoveFolderUseCase(store: store)

        let removed = try await remove(id: folder.id)

        XCTAssertEqual(removed, 2, "two member connections were deleted")
        let conns = await store.all()
        XCTAssertEqual(conns.map(\.id), [outside.id], "only the non-member survives")
        let folders = await store.folders()
        XCTAssertTrue(folders.isEmpty, "the folder record is gone")
    }

    func testDeletingAnEmptyFolderRemovesNoConnections() async throws {
        let folder = Folder(id: UUID(), name: "empty")
        let keep = ssh("keep")
        let store = FakeStore(connections: [keep], folders: [folder])
        let remove = RemoveFolderUseCase(store: store)

        let removed = try await remove(id: folder.id)

        XCTAssertEqual(removed, 0)
        let conns = await store.all()
        XCTAssertEqual(conns.map(\.id), [keep.id])
    }
}

/// Retarget a connection's `folderId`; `nil` ungroups; a no-op writes nothing.
final class MoveConnectionToFolderUseCaseTests: XCTestCase {
    func testMovesAConnectionIntoAFolder() async throws {
        let folder = Folder(id: UUID(), name: "f")
        let conn = ssh("c")
        let store = FakeStore(connections: [conn], folders: [folder])
        let move = MoveConnectionToFolderUseCase(store: store)

        try await move(connectionId: conn.id, folderId: folder.id)

        let stored = await store.all().first { $0.id == conn.id }
        XCTAssertEqual(stored?.folderId, folder.id)
    }

    func testMovingToNilUngroups() async throws {
        let folder = Folder(id: UUID(), name: "f")
        let conn = ssh("c", folder: folder.id)
        let store = FakeStore(connections: [conn], folders: [folder])
        let move = MoveConnectionToFolderUseCase(store: store)

        try await move(connectionId: conn.id, folderId: nil)

        let stored = await store.all().first { $0.id == conn.id }
        XCTAssertNil(stored?.folderId)
    }

    func testAlreadyInTargetIsANoOp() async throws {
        let folder = Folder(id: UUID(), name: "f")
        let conn = ssh("c", folder: folder.id)
        let store = FakeStore(connections: [conn], folders: [folder])
        let move = MoveConnectionToFolderUseCase(store: store)

        try await move(connectionId: conn.id, folderId: folder.id)

        let stored = await store.all().first { $0.id == conn.id }
        XCTAssertEqual(stored?.folderId, folder.id, "no change, still filed")
    }
}

/// Persist the new folder order via the pure rule; a no-op writes nothing.
final class ReorderFoldersUseCaseTests: XCTestCase {
    func testReorderPersistsTheNewOrder() async throws {
        let a = Folder(id: UUID(), name: "a"), b = Folder(id: UUID(), name: "b"), c = Folder(id: UUID(), name: "c")
        let store = FakeStore(folders: [a, b, c])
        let reorder = ReorderFoldersUseCase(store: store)

        try await reorder(from: 2, to: 0)   // move c to the front

        let stored = await store.folders().map(\.id)
        XCTAssertEqual(stored, [c.id, a.id, b.id])
    }

    func testNoOpMovePersistsNothing() async throws {
        let a = Folder(id: UUID(), name: "a"), b = Folder(id: UUID(), name: "b")
        let store = FakeStore(folders: [a, b])
        let reorder = ReorderFoldersUseCase(store: store)

        try await reorder(from: 0, to: 0)

        let calls = await store.reorderFoldersCalls
        XCTAssertEqual(calls, 0, "a move that changes nothing must not touch the store")
    }
}
