import XCTest
import Domain
@testable import Application

/// Contract tests for the duplicate-connection use case, driven through its `ConnectionStore` port.
/// They describe what the use case promises outward — a complete copy under a fresh id, named by the
/// Domain rule, persisted directly below its original — not how it works inside. The seam lets us run
/// against a fake here instead of touching the disk. Don't edit a contract test to make an
/// implementation pass; if the contract is wrong, flag it.
final class DuplicateConnectionUseCaseTests: XCTestCase {

    // Mirrors the per-file fakes in `SaveConnectionUseCaseTests` / `ReorderConnectionsUseCaseTests`,
    // with both write counters so "wrote nothing" is assertable.
    private actor FakeConnectionStore: ConnectionStore {
        private(set) var connections: [Connection] = []
        private(set) var saveCalls = 0
        private(set) var reorderCalls = 0
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
        func reorder(_ orderedIDs: [UUID]) {
            reorderCalls += 1
            connections.sort { a, b in
                (orderedIDs.firstIndex(of: a.id) ?? .max) < (orderedIDs.firstIndex(of: b.id) ?? .max)
            }
        }
        // Folders are read through `Connection.folderId` here; the folder collection is unused.
        func folders() -> [Folder] { [] }
        func saveFolder(_ folder: Folder) {}
        func deleteFolder(id: UUID) {}
        func reorderFolders(_ orderedIDs: [UUID]) {}
    }

    private func ssh(_ name: String) -> Connection {
        Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil))
    }

    private func duplicated(_ outcome: DuplicateConnectionUseCase.Outcome,
                            file: StaticString = #filePath, line: UInt = #line) throws -> Connection {
        guard case let .duplicated(connection) = outcome else {
            XCTFail("expected .duplicated, got \(outcome)", file: file, line: line)
            throw XCTSkip("no connection to assert on")
        }
        return connection
    }

    func testEveryFieldIsCopiedUnderAFreshID() async throws {
        let folder = UUID()
        let source = Connection(id: UUID(), name: "build-box",
                                kind: .ssh(host: "build.internal", port: 2222, user: "ci"),
                                isFavorite: true, customCommand: "tmux new -A -s ci", folderId: folder)
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let copy = try duplicated(try await duplicate(id: source.id))

        XCTAssertNotEqual(copy.id, source.id, "a duplicate is a new record, not the same one")
        XCTAssertEqual(copy.kind, source.kind, "host, port and user come across")
        XCTAssertEqual(copy.customCommand, source.customCommand, "the post-connect command comes across")
        XCTAssertEqual(copy.folderId, folder, "the copy stays in its original's folder")
        XCTAssertTrue(copy.isFavorite, "a favourited connection duplicates as a favourite")
        XCTAssertNil(copy.updatedAt, "the persistence layer stamps updatedAt, not the use case")
    }

    func testALocalFolderConnectionDuplicatesItsPath() async throws {
        let source = Connection(id: UUID(), name: "beacon", kind: .localFolder(path: "/tmp/beacon"))
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let copy = try duplicated(try await duplicate(id: source.id))

        XCTAssertEqual(copy.kind, .localFolder(path: "/tmp/beacon"))
        XCTAssertNil(copy.folderId, "an ungrouped connection duplicates as ungrouped")
    }

    func testTheCopyIsNamedByTheDomainRule() async throws {
        let source = ssh("build-box")
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let copy = try duplicated(try await duplicate(id: source.id))

        XCTAssertEqual(copy.name, "build-box (copy)")
    }

    func testTheCopyIsPersisted() async throws {
        let source = ssh("build-box")
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let copy = try duplicated(try await duplicate(id: source.id))

        let stored = await store.connections
        XCTAssertEqual(stored.count, 2, "the original is kept and the copy added")
        XCTAssertTrue(stored.contains { $0.id == copy.id }, "the returned copy is the stored one")
    }

    func testTheCopyIsStoredDirectlyAfterItsOriginal() async throws {
        let first = ssh("first"), source = ssh("build-box"), last = ssh("last")
        let store = FakeConnectionStore(seed: [first, source, last])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let copy = try duplicated(try await duplicate(id: source.id))

        let stored = await store.connections.map(\.id)
        XCTAssertEqual(stored, [first.id, source.id, copy.id, last.id],
                       "the copy lands under its original, not at the end of the list")
    }

    func testRepeatedDuplicationUniquifiesTheName() async throws {
        let source = ssh("build-box")
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let first = try duplicated(try await duplicate(id: source.id))
        let second = try duplicated(try await duplicate(id: source.id))

        XCTAssertEqual(first.name, "build-box (copy)")
        XCTAssertEqual(second.name, "build-box (copy 2)", "the second copy must not collide with the first")
    }

    func testDuplicatingACopyNumbersFromTheOriginal() async throws {
        let source = ssh("build-box")
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let first = try duplicated(try await duplicate(id: source.id))
        let second = try duplicated(try await duplicate(id: first.id))

        XCTAssertEqual(second.name, "build-box (copy 2)", "a copy of a copy doesn't stack suffixes")
    }

    func testDuplicatingACopyPlacesItUnderThatCopy() async throws {
        let source = ssh("build-box")
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let first = try duplicated(try await duplicate(id: source.id))
        let second = try duplicated(try await duplicate(id: first.id))

        let stored = await store.connections.map(\.id)
        XCTAssertEqual(stored, [source.id, first.id, second.id],
                       "each copy sits under the row it was made from")
    }

    func testAnUnknownIDIsNotFoundAndWritesNothing() async throws {
        let source = ssh("build-box")
        let store = FakeConnectionStore(seed: [source])
        let duplicate = DuplicateConnectionUseCase(store: store)

        let outcome = try await duplicate(id: UUID())

        XCTAssertEqual(outcome, .notFound)
        let saves = await store.saveCalls
        let reorders = await store.reorderCalls
        XCTAssertEqual(saves, 0, "nothing to copy must not touch the store")
        XCTAssertEqual(reorders, 0)
        let stored = await store.connections
        XCTAssertEqual(stored.count, 1)
    }
}
