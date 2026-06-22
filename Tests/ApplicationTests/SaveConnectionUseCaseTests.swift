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
