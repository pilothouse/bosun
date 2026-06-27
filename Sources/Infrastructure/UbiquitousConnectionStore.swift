import Application
import Domain
import Foundation

/// iCloud sync decorator for the `ConnectionStore` port (issue #83). Wraps the local
/// `JSONFileConnectionStore` — which stays the fast offline read cache and source of truth — and adds
/// `NSUbiquitousKeyValueStore` as the sync transport. An `actor` so the read-modify-write of the
/// snapshot is serialized; iCloud is reached only through the `UbiquitousKeyValueStore` seam.
///
/// Writes are stamped (`Connection`/`Folder.updatedAt`), deletions tombstoned, and reorders timestamped
/// — the metadata the pure `ConnectionSyncMerge` needs. Per-record metadata that isn't on the entities
/// (tombstones + order timestamps) lives in a small local sidecar so it survives a relaunch. When
/// sync is **disabled** (the opt-in default) the decorator is a near-transparent pass-through: it still
/// stamps `updatedAt` (harmless, future-proofs the first sync) but records no tombstones, writes no
/// sidecar, and never touches iCloud — so the local-only path is unchanged.
public actor UbiquitousConnectionStore: ConnectionStore {
    /// The decorator's own metadata, kept beside the connections file. The entity records live in the
    /// wrapped store; only what the merge needs *besides* them is here.
    private struct SyncMeta: Codable {
        var connectionTombstones: [Tombstone] = []
        var folderTombstones: [Tombstone] = []
        var connectionsOrderUpdatedAt: Date?
        var foldersOrderUpdatedAt: Date?
    }

    private let local: JSONFileConnectionStore
    private let cloud: any UbiquitousKeyValueStore
    private let metaURL: URL
    private let key: String
    private var enabled: Bool
    private var meta: SyncMeta
    private var onRemoteChange: (@Sendable () -> Void)?

    /// Production constructor — wraps `local` and the real `NSUbiquitousKeyValueStore`.
    public init(local: JSONFileConnectionStore,
                metaURL: URL = UbiquitousConnectionStore.defaultMetaURL(),
                key: String = "bosun.connections", enabled: Bool = false) {
        self.local = local
        self.cloud = ICloudKeyValueStore()
        self.metaURL = metaURL
        self.key = key
        self.enabled = enabled
        self.meta = (try? Self.loadMeta(metaURL)) ?? SyncMeta()
    }

    /// Injectable constructor — tests pass an in-memory `UbiquitousKeyValueStore` here. Internal so the
    /// KVS seam stays an Infrastructure detail (the public surface is just the production init above).
    init(local: JSONFileConnectionStore, cloud: any UbiquitousKeyValueStore,
         metaURL: URL = UbiquitousConnectionStore.defaultMetaURL(),
         key: String = "bosun.connections", enabled: Bool = false) {
        self.local = local
        self.cloud = cloud
        self.metaURL = metaURL
        self.key = key
        self.enabled = enabled
        self.meta = (try? Self.loadMeta(metaURL)) ?? SyncMeta()
    }

    /// `~/Library/Application Support/bosun/connections-sync.json`, beside `connections.json`.
    public static func defaultMetaURL() -> URL {
        JSONFileConnectionStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("connections-sync.json")
    }

    // MARK: Lifecycle

    /// Wire the external-change observer and remember how to tell the App layer to refresh (the signal
    /// is a bare "reload now" — the App layer re-reads the merged store and repaints). Call once at
    /// launch, after construction. Does not reconcile here — `setEnabled` drives the initial sync so
    /// the order (observe, then enable) is explicit.
    public func start(onRemoteChange: @escaping @Sendable () -> Void) {
        self.onRemoteChange = onRemoteChange
        cloud.observeExternalChanges { [weak self] in
            Task { await self?.reconcile() }
        }
    }

    /// Turn sync on or off (the Settings toggle). Turning it on reconciles immediately: pull the cloud
    /// snapshot, merge, and seed the cloud if it's empty.
    public func setEnabled(_ value: Bool) async {
        guard value != enabled else { return }
        enabled = value
        if enabled { await reconcile() }
    }

    /// Force a reconcile against whatever iCloud currently holds. The observer fires this on a remote
    /// change; it's also the deterministic seam tests use to drive one.
    public func syncNow() async { await reconcile() }

    // MARK: ConnectionStore — reads delegate straight to the offline store

    public func all() async throws -> [Connection] { try await local.all() }
    public func folders() async throws -> [Folder] { try await local.folders() }

    // MARK: ConnectionStore — writes mirror to local, then sync

    public func save(_ connection: Connection) async throws {
        let isNew = try await !local.all().contains(where: { $0.id == connection.id })
        var stamped = connection
        stamped.updatedAt = Date()
        try await local.save(stamped)
        guard enabled else { return }
        meta.connectionTombstones.removeAll { $0.id == connection.id }   // a (re)create clears its tombstone
        if isNew { meta.connectionsOrderUpdatedAt = Date() }             // append changed the order
        try await syncAfterWrite()
    }

    public func delete(id: UUID) async throws {
        try await local.delete(id: id)
        guard enabled else { return }
        tombstone(&meta.connectionTombstones, id: id)
        meta.connectionsOrderUpdatedAt = Date()
        try await syncAfterWrite()
    }

    public func reorder(_ orderedIDs: [UUID]) async throws {
        try await local.reorder(orderedIDs)
        guard enabled else { return }
        meta.connectionsOrderUpdatedAt = Date()
        try await syncAfterWrite()
    }

    public func saveFolder(_ folder: Folder) async throws {
        let isNew = try await !local.folders().contains(where: { $0.id == folder.id })
        var stamped = folder
        stamped.updatedAt = Date()
        try await local.saveFolder(stamped)
        guard enabled else { return }
        meta.folderTombstones.removeAll { $0.id == folder.id }
        if isNew { meta.foldersOrderUpdatedAt = Date() }
        try await syncAfterWrite()
    }

    public func deleteFolder(id: UUID) async throws {
        try await local.deleteFolder(id: id)
        guard enabled else { return }
        tombstone(&meta.folderTombstones, id: id)
        meta.foldersOrderUpdatedAt = Date()
        try await syncAfterWrite()
    }

    public func reorderFolders(_ orderedIDs: [UUID]) async throws {
        try await local.reorderFolders(orderedIDs)
        guard enabled else { return }
        meta.foldersOrderUpdatedAt = Date()
        try await syncAfterWrite()
    }

    // MARK: Sync internals

    /// Persist the sidecar and push the current snapshot to iCloud after a local write.
    private func syncAfterWrite() async throws {
        try persistMeta()
        await push()
    }

    /// Encode the current local + sidecar state and hand it to iCloud. Best-effort: a failure here
    /// never propagates to the write that triggered it (the local mirror already succeeded).
    private func push() async {
        guard enabled, let snapshot = try? await currentSnapshot(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        cloud.set(data, forKey: key)
        cloud.synchronize()
    }

    /// Pull the cloud snapshot, merge it into local, write the result back to both, and tell the App
    /// layer to refresh. With nothing in the cloud yet, seed it from local instead. The handler the
    /// observer fires and the `setEnabled(true)` initial sync both land here.
    private func reconcile() async {
        guard enabled else { return }
        guard let data = cloud.data(forKey: key),
              let remote = try? JSONDecoder().decode(ConnectionSyncSnapshot.self, from: data) else {
            await push()   // first device on this account → publish what we have
            return
        }
        guard let localSnapshot = try? await currentSnapshot() else { return }
        let merged = ConnectionSyncMerge.merge(local: localSnapshot, remote: remote)

        try? await local.replaceAll(connections: merged.connections, folders: merged.folders)
        meta = SyncMeta(
            connectionTombstones: merged.connectionTombstones,
            folderTombstones: merged.folderTombstones,
            connectionsOrderUpdatedAt: merged.connectionsOrderUpdatedAt,
            foldersOrderUpdatedAt: merged.foldersOrderUpdatedAt)
        try? persistMeta()

        if let encoded = try? JSONEncoder().encode(merged) {
            cloud.set(encoded, forKey: key)
            cloud.synchronize()
        }
        onRemoteChange?()
    }

    private func currentSnapshot() async throws -> ConnectionSyncSnapshot {
        ConnectionSyncSnapshot(
            connections: try await local.all(),
            folders: try await local.folders(),
            connectionTombstones: meta.connectionTombstones,
            folderTombstones: meta.folderTombstones,
            connectionsOrderUpdatedAt: meta.connectionsOrderUpdatedAt,
            foldersOrderUpdatedAt: meta.foldersOrderUpdatedAt)
    }

    // MARK: Tombstones + sidecar

    private func tombstone(_ list: inout [Tombstone], id: UUID) {
        list.removeAll { $0.id == id }
        list.append(Tombstone(id: id, deletedAt: Date()))
    }

    private func persistMeta() throws {
        try FileManager.default.createDirectory(
            at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL, options: .atomic)
    }

    private static func loadMeta(_ url: URL) throws -> SyncMeta {
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncMeta() }
        return try JSONDecoder().decode(SyncMeta.self, from: Data(contentsOf: url))
    }
}
