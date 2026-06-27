import XCTest
import Domain
@testable import Application

/// Contract tests for the reorder-connections use case, driven through its `ConnectionStore` port.
/// The seam lets us run against a fake here instead of touching the disk; the use case promises to
/// persist the new global order produced by the pure `ConnectionOrdering` rule, and to write
/// nothing when a move changes nothing.
final class ReorderConnectionsUseCaseTests: XCTestCase {

    private actor FakeConnectionStore: ConnectionStore {
        private(set) var connections: [Connection]
        private(set) var reorderCalls = 0
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
            reorderCalls += 1
            connections.sort { a, b in
                (orderedIDs.firstIndex(of: a.id) ?? .max) < (orderedIDs.firstIndex(of: b.id) ?? .max)
            }
        }
    }

    private func ssh(_ name: String) -> Connection {
        Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil))
    }

    func testReorderPersistsTheNewGlobalOrder() async throws {
        let a = ssh("a"), b = ssh("b"), c = ssh("c")
        let store = FakeConnectionStore(seed: [a, b, c])
        let reorder = ReorderConnectionsUseCase(store: store)

        // Section spans the whole list; move the last entry to the front.
        try await reorder(sectionIDs: [a.id, b.id, c.id], from: 2, to: 0)

        let stored = await store.connections.map(\.id)
        XCTAssertEqual(stored, [c.id, a.id, b.id])
    }

    func testReorderWithinASectionLeavesNonMembersFixed() async throws {
        // Global [a, b, c, d]; reorder the SSH section [a, c] (b, d sit between/after them).
        let a = ssh("a"), b = ssh("b"), c = ssh("c"), d = ssh("d")
        let store = FakeConnectionStore(seed: [a, b, c, d])
        let reorder = ReorderConnectionsUseCase(store: store)

        try await reorder(sectionIDs: [a.id, c.id], from: 1, to: 0)   // move c before a

        let stored = await store.connections.map(\.id)
        XCTAssertEqual(stored, [c.id, b.id, a.id, d.id], "only a/c slots swap; b and d stay put")
    }

    func testNoOpMovePersistsNothing() async throws {
        let a = ssh("a"), b = ssh("b")
        let store = FakeConnectionStore(seed: [a, b])
        let reorder = ReorderConnectionsUseCase(store: store)

        try await reorder(sectionIDs: [a.id, b.id], from: 0, to: 0)

        let calls = await store.reorderCalls
        XCTAssertEqual(calls, 0, "a move that changes nothing must not touch the store")
        let stored = await store.connections.map(\.id)
        XCTAssertEqual(stored, [a.id, b.id])
    }
}
