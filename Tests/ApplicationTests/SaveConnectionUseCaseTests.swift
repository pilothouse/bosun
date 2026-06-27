import XCTest
import Domain
@testable import Application

/// Contract tests for the save-connection use case, driven through its `ConnectionStore` port.
/// The seam lets us run against a fake here instead of touching the disk.
final class SaveConnectionUseCaseTests: XCTestCase {

    private actor FakeConnectionStore: ConnectionStore {
        private(set) var connections: [Connection] = []
        init(seed: [Connection] = []) { connections = seed }
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
        // Folders are unused by these connection-save tests; conform with no-ops.
        func folders() -> [Folder] { [] }
        func saveFolder(_ folder: Folder) {}
        func deleteFolder(id: UUID) {}
        func reorderFolders(_ orderedIDs: [UUID]) {}
    }

    func testValidNewDraftIsSavedWithFreshID() async throws {
        let store = FakeConnectionStore()
        let save = SaveConnectionUseCase(store: store)
        let draft = ConnectionDraft(id: nil, name: "prod", kind: .ssh(host: "10.0.0.1", port: 22, user: nil))

        let outcome = try await save(draft)

        guard case let .saved(connection) = outcome else {
            return XCTFail("expected .saved, got \(outcome)")
        }
        let stored = await store.connections
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, connection.id)
        XCTAssertEqual(connection.name, "prod")
    }

    func testEditDraftKeepsItsID() async throws {
        let existing = Connection(id: UUID(), name: "old", kind: .localFolder(path: "~/dev/old"))
        let store = FakeConnectionStore(seed: [existing])
        let save = SaveConnectionUseCase(store: store)
        let draft = ConnectionDraft(id: existing.id, name: "renamed", kind: .localFolder(path: "~/dev/new"))

        let outcome = try await save(draft)

        guard case let .saved(connection) = outcome else {
            return XCTFail("expected .saved, got \(outcome)")
        }
        XCTAssertEqual(connection.id, existing.id, "edit must preserve the id")
        let stored = await store.connections
        XCTAssertEqual(stored.count, 1, "edit upserts, not appends")
        XCTAssertEqual(stored.first?.name, "renamed")
    }

    func testCustomCommandIsSavedAndBlankIsNormalizedToNil() async throws {
        let store = FakeConnectionStore()
        let save = SaveConnectionUseCase(store: store)

        let withCommand = ConnectionDraft(id: nil, name: "dev", kind: .ssh(host: "h", port: 22, user: "u"),
                                          customCommand: "  tmux new -n dev  ")
        guard case let .saved(c1) = try await save(withCommand) else { return XCTFail("expected .saved") }
        XCTAssertEqual(c1.customCommand, "tmux new -n dev", "trimmed custom command is persisted")

        let blankCommand = ConnectionDraft(id: nil, name: "plain", kind: .ssh(host: "h", port: 22, user: "u"),
                                           customCommand: "   ")
        guard case let .saved(c2) = try await save(blankCommand) else { return XCTFail("expected .saved") }
        XCTAssertNil(c2.customCommand, "a blank custom command persists as nil")
    }

    func testInvalidDraftIsNotSaved() async throws {
        let store = FakeConnectionStore()
        let save = SaveConnectionUseCase(store: store)
        let draft = ConnectionDraft(id: nil, name: "", kind: .ssh(host: "", port: 0, user: nil))

        let outcome = try await save(draft)

        guard case let .invalid(errors) = outcome else {
            return XCTFail("expected .invalid, got \(outcome)")
        }
        XCTAssertFalse(errors.isEmpty)
        let stored = await store.connections
        XCTAssertTrue(stored.isEmpty, "an invalid draft must not be persisted")
    }
}
