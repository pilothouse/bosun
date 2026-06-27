import XCTest
@testable import Application
@testable import Domain
@testable import Infrastructure

/// Contract tests for the on-disk connection adapter: it round-trips the `{connections, folders}`
/// envelope, and — the migration that matters — decodes a legacy bare `[Connection]` array (a file
/// written before folders existed) as connections-with-no-folders, upgrading it to the envelope on
/// the next write. A fresh store with no file is empty rather than throwing.
final class JSONFileConnectionStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-conn-tests-\(UUID().uuidString)", isDirectory: true)
        url = dir.appendingPathComponent("connections.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> JSONFileConnectionStore { JSONFileConnectionStore(url: url) }

    private func ssh(_ name: String, folder: UUID? = nil) -> Connection {
        Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil), folderId: folder)
    }

    func testEmptyWhenNoFile() async throws {
        let s = store()
        let conns = try await s.all()
        let folders = try await s.folders()
        XCTAssertTrue(conns.isEmpty)
        XCTAssertTrue(folders.isEmpty)
    }

    func testRoundTripsConnectionsAndFolders() async throws {
        let folder = Folder(id: UUID(), name: "Project Acme")
        let filed = ssh("db", folder: folder.id)
        let loose = ssh("scratch")

        let writer = store()
        try await writer.saveFolder(folder)
        try await writer.save(filed)
        try await writer.save(loose)

        // A fresh instance reads from disk (no in-memory cache carried over).
        let reader = store()
        let conns = try await reader.all()
        let folders = try await reader.folders()
        XCTAssertEqual(conns.map(\.id), [filed.id, loose.id])
        XCTAssertEqual(conns.first { $0.id == filed.id }?.folderId, folder.id)
        XCTAssertEqual(folders.map(\.id), [folder.id])
    }

    func testDecodesLegacyBareArrayAsUngroupedConnections() async throws {
        // A connections.json from before folders: a bare top-level array, no envelope, no folderId.
        let legacy = """
        [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "db-primary",
            "kind": { "ssh": { "host": "db.example.com", "port": 22, "user": "ops" } },
            "isFavorite": true
          }
        ]
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.write(to: url)

        let s = store()
        let conns = try await s.all()
        let folders = try await s.folders()
        XCTAssertEqual(conns.count, 1)
        XCTAssertEqual(conns.first?.name, "db-primary")
        XCTAssertNil(conns.first?.folderId, "legacy connections load ungrouped")
        XCTAssertTrue(folders.isEmpty)
    }

    func testWritingUpgradesLegacyFileToEnvelope() async throws {
        let legacy = """
        [ { "id": "00000000-0000-0000-0000-000000000002", "name": "x",
            "kind": { "localFolder": { "path": "/tmp" } }, "isFavorite": false } ]
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.write(to: url)

        // Any mutation rewrites the file in the new shape.
        let s = store()
        try await s.saveFolder(Folder(id: UUID(), name: "f"))

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"connections\""), "rewritten as an envelope")
        XCTAssertTrue(raw.contains("\"folders\""))

        // And it's readable as the envelope by a fresh instance.
        let reader = store()
        let connCount = try await reader.all().count
        let folderCount = try await reader.folders().count
        XCTAssertEqual(connCount, 1)
        XCTAssertEqual(folderCount, 1)
    }

    func testReorderFoldersPersistsOrder() async throws {
        let a = Folder(id: UUID(), name: "a"), b = Folder(id: UUID(), name: "b"), c = Folder(id: UUID(), name: "c")
        let writer = store()
        for f in [a, b, c] { try await writer.saveFolder(f) }

        try await writer.reorderFolders([c.id, a.id, b.id])

        let reader = store()
        let order = try await reader.folders().map(\.id)
        XCTAssertEqual(order, [c.id, a.id, b.id])
    }
}
