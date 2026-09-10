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

    // MARK: Reporting — what the App layer logs and shows under the Settings checkbox

    func testSuccessfulPushReportsSynced() async throws {
        let store = makeStore(enabled: true)
        let status = StatusRecorder()
        await store.start(onRemoteChange: {}, onStatus: { status.record($0) })

        try await store.save(ssh("db"))

        guard case .synced? = status.last else {
            return XCTFail("expected .synced, got \(String(describing: status.last))")
        }
    }

    /// The regression that made this whole feature invisible: `synchronize()` returning `false` — what
    /// an unentitled build does on every single call — used to be discarded, so a dead sync looked
    /// exactly like a working one. It must be reported, and it must still not fail the user's edit:
    /// sync is best-effort, and the local store remains the source of truth.
    func testSynchronizeFailureIsReportedAndLocalWriteStillLands() async throws {
        let store = makeStore(enabled: true)
        let status = StatusRecorder()
        await store.start(onRemoteChange: {}, onStatus: { status.record($0) })
        fake.synchronizeResult = false

        let conn = ssh("db")
        try await store.save(conn)   // must not throw

        let reader = JSONFileConnectionStore(url: connURL)
        let localIDs = try await reader.all().map(\.id)
        XCTAssertEqual(localIDs, [conn.id], "the local write is unaffected")
        guard case .failed? = status.last else {
            return XCTFail("expected .failed, got \(String(describing: status.last))")
        }
    }

    /// A payload written by a newer schema version — or a truncated one — used to fall into the same
    /// branch as "the cloud is empty", whose response is to publish local state. That silently
    /// clobbered the other device's data. An unreadable remote must be left exactly as it stands.
    func testUnreadableRemoteIsReportedAndLeftUntouched() async throws {
        let garbage = Data("{\"schemaVersion\":99,\"whatever\":true}".utf8)
        fake.set(garbage, forKey: key)

        let store = makeStore(enabled: true)
        let status = StatusRecorder()
        let fired = Flag()
        await store.start(onRemoteChange: { fired.mark() }, onStatus: { status.record($0) })
        await store.syncNow()

        XCTAssertEqual(fake.data(forKey: key), garbage, "the unreadable snapshot is not overwritten")
        XCTAssertFalse(fired.value, "nothing merged, so the rail is not told to reload")
        guard case .failed? = status.last else {
            return XCTFail("expected .failed, got \(String(describing: status.last))")
        }
    }

    /// Leaving the bad snapshot alone in `reconcile` is only worth anything if the user's next edit
    /// doesn't publish straight over it — which is exactly what the plain write path would do.
    func testLocalWritesDoNotPublishOverAnUnreadableRemote() async throws {
        let garbage = Data("{\"schemaVersion\":99,\"whatever\":true}".utf8)
        fake.set(garbage, forKey: key)

        let store = makeStore(enabled: true)
        let status = StatusRecorder()
        await store.start(onRemoteChange: {}, onStatus: { status.record($0) })
        await store.syncNow()          // discovers it can't read the remote

        let conn = ssh("added-after")
        try await store.save(conn)     // the edit still lands locally...

        let reader = JSONFileConnectionStore(url: connURL)
        let localIDs = try await reader.all().map(\.id)
        XCTAssertEqual(localIDs, [conn.id], "the local write is unaffected")
        XCTAssertEqual(fake.data(forKey: key), garbage, "...but it is not published over the remote")
    }

    /// And it recovers on its own: once the cloud holds something readable again (the other device
    /// rewrote it, or this one was upgraded), publishing resumes with no user action.
    func testPublishingResumesOnceTheRemoteBecomesReadable() async throws {
        fake.set(Data("not json".utf8), forKey: key)
        let store = makeStore(enabled: true)
        await store.start(onRemoteChange: {}, onStatus: { _ in })
        await store.syncNow()

        let readable = ConnectionSyncSnapshot(connections: [ssh("from-the-other-mac")])
        fake.set(try JSONEncoder().encode(readable), forKey: key)
        await store.syncNow()

        let conn = ssh("added-after")
        try await store.save(conn)
        let pushedIDs = try pushedSnapshot()?.connections.map(\.id)
        XCTAssertEqual(pushedIDs?.contains(conn.id), true, "the new connection reaches iCloud again")
    }

    /// An empty cloud is the other half of that split: a first device on the account still seeds it.
    func testEmptyRemoteIsSeededFromLocal() async throws {
        let store = makeStore(enabled: true)
        await store.start(onRemoteChange: {}, onStatus: { _ in })
        let conn = ssh("db")
        try await store.save(conn)
        await store.syncNow()

        let pushedIDs = try pushedSnapshot()?.connections.map(\.id)
        XCTAssertEqual(pushedIDs, [conn.id])
    }

    func testTurningSyncOffReportsOffAndLeavesTheCloudAlone() async throws {
        let store = makeStore(enabled: true)
        let status = StatusRecorder()
        await store.start(onRemoteChange: {}, onStatus: { status.record($0) })
        try await store.save(ssh("db"))
        let published = fake.data(forKey: key)

        await store.setEnabled(false)

        guard case .off? = status.last else {
            return XCTFail("expected .off, got \(String(describing: status.last))")
        }
        XCTAssertEqual(fake.data(forKey: key), published,
                       "opting out stops participating; it does not wipe the other devices")
    }
}

/// In-memory stand-in for `NSUbiquitousKeyValueStore`. `@unchecked Sendable` — a lock guards the dict.
///
/// `synchronizeResult` is settable because it used to be hardcoded `true`, which is exactly the case
/// that hid the real bug: on an unentitled build the live store returns `false` from every call, and
/// the production code discarded the value, so a completely dead sync passed these tests.
private final class FakeKeyValueStore: UbiquitousKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var handler: (@Sendable () -> Void)?
    private var syncResult = true

    var synchronizeResult: Bool {
        get { lock.withLock { syncResult } }
        set { lock.withLock { syncResult = newValue } }
    }

    func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
    func set(_ data: Data?, forKey key: String) { lock.withLock { storage[key] = data } }
    func synchronize() -> Bool { lock.withLock { syncResult } }
    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }
}

/// Collects what the decorator reported, the way the App layer does. Lock-guarded for the same reason
/// as `Flag`: the callback is `@Sendable`.
private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncStatus] = []
    var all: [SyncStatus] { lock.withLock { stored } }
    var last: SyncStatus? { lock.withLock { stored.last } }
    func record(_ status: SyncStatus) { lock.withLock { stored.append(status) } }
}

/// A lock-guarded flag the `@Sendable` remote-change callback can set without tripping Sendable
/// diagnostics — the synchronous twin of the callback the App layer installs.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func mark() { lock.withLock { stored = true } }
}
