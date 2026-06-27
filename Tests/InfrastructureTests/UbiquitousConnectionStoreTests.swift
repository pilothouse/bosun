import XCTest
@testable import Application
@testable import Domain
@testable import Infrastructure

/// Contract tests for the iCloud sync decorator, exercised against an in-memory `UbiquitousKeyValueStore`
/// fake so the full write-through / tombstone / merge path runs with no live iCloud account. The wrapped
/// local store is a real `JSONFileConnectionStore` over a temp file (the `JSONFileConnectionStoreTests`
/// style), so "writes through to local" is a genuine on-disk assertion.
final class UbiquitousConnectionStoreTests: XCTestCase {
    private var dir: URL!
    private var connURL: URL!
    private var metaURL: URL!
    private var fake: FakeKeyValueStore!
    private let key = "test.connections"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-sync-tests-\(UUID().uuidString)", isDirectory: true)
        connURL = dir.appendingPathComponent("connections.json")
        metaURL = dir.appendingPathComponent("connections-sync.json")
        fake = FakeKeyValueStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(enabled: Bool) -> UbiquitousConnectionStore {
        UbiquitousConnectionStore(
            local: JSONFileConnectionStore(url: connURL),
            cloud: fake, metaURL: metaURL, key: key, enabled: enabled)
    }

    private func ssh(_ name: String) -> Connection {
        Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil))
    }

    private func pushedSnapshot() throws -> ConnectionSyncSnapshot? {
        guard let data = fake.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(ConnectionSyncSnapshot.self, from: data)
    }

    func testSaveWritesThroughToLocalAndPushesSnapshot() async throws {
        let store = makeStore(enabled: true)
        let conn = ssh("db")
        try await store.save(conn)

        // Local on-disk mirror (a fresh reader hits the file, not the cache).
        let reader = JSONFileConnectionStore(url: connURL)
        let localIDs = try await reader.all().map(\.id)
        XCTAssertEqual(localIDs, [conn.id])

        // And the cloud now carries the same connection, stamped with an updatedAt.
        let snapshot = try pushedSnapshot()
        XCTAssertEqual(snapshot?.connections.map(\.id), [conn.id])
        XCTAssertNotNil(snapshot?.connections.first?.updatedAt, "the push stamps updatedAt")
    }

    func testDeleteRecordsTombstoneInPushedSnapshot() async throws {
        let store = makeStore(enabled: true)
        let conn = ssh("db")
        try await store.save(conn)
        try await store.delete(id: conn.id)

        let snapshot = try pushedSnapshot()
        XCTAssertTrue(snapshot?.connections.isEmpty ?? false, "the record is gone from the cloud blob")
        XCTAssertEqual(snapshot?.connectionTombstones.map(\.id), [conn.id], "a tombstone carries the delete")
    }

    func testDisabledMirrorsLocallyButNeverTouchesICloud() async throws {
        let store = makeStore(enabled: false)
        let conn = ssh("db")
        try await store.save(conn)

        let reader = JSONFileConnectionStore(url: connURL)
        let localIDs = try await reader.all().map(\.id)
        XCTAssertEqual(localIDs, [conn.id], "local write still happens")
        XCTAssertNil(fake.data(forKey: key), "disabled sync pushes nothing to iCloud")
    }

    func testRemoteChangeMergesIntoLocalAndFiresCallback() async throws {
        let store = makeStore(enabled: true)
        let local = ssh("local-a")
        try await store.save(local)

        let fired = Flag()
        await store.start { fired.mark() }

        // Another device publishes a snapshot that also holds a connection we've never seen.
        let remote = ssh("remote-b")
        let cloudSnapshot = ConnectionSyncSnapshot(connections: [remote],
                                                   connectionsOrderUpdatedAt: Date())
        fake.set(try JSONEncoder().encode(cloudSnapshot), forKey: key)
        await store.syncNow()

        let ids = Set(try await store.all().map(\.id))
        XCTAssertTrue(ids.contains(local.id), "local connection survives the merge")
        XCTAssertTrue(ids.contains(remote.id), "the remote connection is merged in")
        XCTAssertTrue(fired.value, "the App layer is told to refresh the rail")
    }
}

/// In-memory stand-in for `NSUbiquitousKeyValueStore`. `@unchecked Sendable` — a lock guards the dict.
private final class FakeKeyValueStore: UbiquitousKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var handler: (@Sendable () -> Void)?

    func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
    func set(_ data: Data?, forKey key: String) { lock.withLock { storage[key] = data } }
    func synchronize() -> Bool { true }
    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }
}

/// A lock-guarded flag the `@Sendable` remote-change callback can set without tripping Sendable
/// diagnostics — the synchronous twin of the callback the App layer installs.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func mark() { lock.withLock { stored = true } }
}
