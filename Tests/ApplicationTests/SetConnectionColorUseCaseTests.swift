import XCTest
import Domain
@testable import Application

/// Contract tests for the quick color change behind the rail's "Color ▸" menu (#102), driven through
/// the `ConnectionStore` port. They describe what the use case promises — the color lands on the
/// stored connection, `nil` clears it, and a change that changes nothing writes nothing — not how it
/// works inside. Don't edit a contract test to make an implementation pass; if the contract is wrong,
/// flag it.
final class SetConnectionColorUseCaseTests: XCTestCase {

    // Mirrors the per-file fakes in `SaveConnectionUseCaseTests` / `DuplicateConnectionUseCaseTests`,
    // with a save counter so "wrote nothing" is assertable.
    private actor FakeConnectionStore: ConnectionStore {
        private(set) var connections: [Connection] = []
        private(set) var saveCalls = 0
        init(seed: [Connection] = []) { connections = seed }
        func all() -> [Connection] { connections }
        func save(_ connection: Connection) {
            saveCalls += 1
            if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[idx] = connection
            } else {
                connections.append(connection)
            }
        }
        func delete(id: UUID) { connections.removeAll { $0.id == id } }
        func reorder(_ orderedIDs: [UUID]) {}
        // Colors live on the connection record; the folder collection is unused.
        func folders() -> [Folder] { [] }
        func saveFolder(_ folder: Folder) {}
        func deleteFolder(id: UUID) {}
        func reorderFolders(_ orderedIDs: [UUID]) {}
    }

    private func ssh(_ name: String, color: ConnectionColor? = nil) -> Connection {
        Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil), isFavorite: true,
                   customCommand: "tmux", folderId: UUID(), color: color)
    }

    func testSetsTheColorAndKeepsEveryOtherField() async throws {
        let original = ssh("prod")
        let store = FakeConnectionStore(seed: [original])
        let setColor = SetConnectionColorUseCase(store: store)

        try await setColor(connectionId: original.id, color: .red)

        let stored = await store.connections.first
        XCTAssertEqual(stored?.color, .red)
        var expected = original
        expected.color = .red
        XCTAssertEqual(stored, expected, "only the color changes")
    }

    func testNilClearsTheColor() async throws {
        let original = ssh("prod", color: .orange)
        let store = FakeConnectionStore(seed: [original])
        let setColor = SetConnectionColorUseCase(store: store)

        try await setColor(connectionId: original.id, color: nil)

        let stored = await store.connections.first
        XCTAssertNil(stored?.color)
    }

    func testTheSameColorWritesNothing() async throws {
        let original = ssh("prod", color: .green)
        let store = FakeConnectionStore(seed: [original])
        let setColor = SetConnectionColorUseCase(store: store)

        try await setColor(connectionId: original.id, color: .green)

        let saves = await store.saveCalls
        XCTAssertEqual(saves, 0, "a no-op change must not bump updatedAt or push to iCloud")
    }

    func testAnUnknownIDWritesNothing() async throws {
        let store = FakeConnectionStore(seed: [ssh("prod")])
        let setColor = SetConnectionColorUseCase(store: store)

        try await setColor(connectionId: UUID(), color: .blue)

        let saves = await store.saveCalls
        XCTAssertEqual(saves, 0)
    }
}
