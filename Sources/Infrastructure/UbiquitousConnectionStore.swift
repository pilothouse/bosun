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
    private var onStatusChange: (@Sendable (SyncStatus) -> Void)?

    /// Set when the cloud holds a snapshot this build cannot decode — a payload from a newer schema
    /// version, or a corrupt one. While it is set, this device publishes nothing: leaving the bad
    /// snapshot alone in `reconcile` would be pointless if the user's very next edit pushed over it.
    /// Cleared the moment a decode succeeds (they upgraded, or the other device rewrote it), so it
    /// recovers on its own with no user action.
    private var remoteUnreadable = false

    /// Said in two places (the refusal above and the reconcile that discovered it), so it is written
    /// once. Phrased for the Settings pane: the user's options are to upgrade or to wait.
    private static let unreadableRemote = "iCloud holds a connection list this version can't read"

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
    ///
    /// `onStatus` is the diagnostic seam: every push and every reconcile reports its outcome through
    /// it, and the App layer logs it and shows it under the Settings checkbox. Reporting outward
    /// rather than logging from here keeps `Log` (which lives in the App layer) out of Infrastructure,
    /// and gives the user-visible hint and the log line one source of truth.
    public func start(onRemoteChange: @escaping @Sendable () -> Void,
                      onStatus: (@Sendable (SyncStatus) -> Void)? = nil) {
        self.onRemoteChange = onRemoteChange
        self.onStatusChange = onStatus
        cloud.observeExternalChanges { [weak self] in
            Task { await self?.reconcile() }
        }
    }

    /// Turn sync on or off (the Settings toggle). Turning it on reconciles immediately: pull the cloud
    /// snapshot, merge, and seed the cloud if it's empty.
    public func setEnabled(_ value: Bool) async {
        guard value != enabled else { return }
        enabled = value
        guard enabled else {
            // The cloud key is deliberately left as it stands. Opting out is "stop participating", not
            // "wipe the other devices" — and re-ticking the box should find the account as it was.
            report(.off)
            return
        }
        report(.syncing)
        await reconcile()
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
    /// never propagates to the write that triggered it (the local mirror already succeeded), but it
    /// is now reported rather than swallowed.
    private func push() async {
        guard enabled else { return }
        guard !remoteUnreadable else {
            report(.failed(Self.unreadableRemote))
            return
        }
        guard let snapshot = try? await currentSnapshot() else {
            report(.failed("couldn't read the local connections file"))
            return
        }
        report(commit(snapshot))
    }

    /// Encode a snapshot and hand it to iCloud, reporting what actually happened.
    ///
    /// `synchronize()`'s return value used to be discarded at both call sites, which is precisely how
    /// this feature shipped dead: on a build carrying no KVS entitlement it returns `false` on every
    /// call and the readback is always nil, and nothing anywhere noticed. It is the one signal the
    /// store gives us, so it is the one we act on.
    private func commit(_ snapshot: ConnectionSyncSnapshot) -> SyncStatus {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return .failed("couldn't encode the connection list")
        }
        cloud.set(data, forKey: key)
        guard cloud.synchronize() else {
            return .failed("iCloud rejected the write")
        }
        return .synced(Date())
    }

    /// Pull the cloud snapshot, merge it into local, write the result back to both, and tell the App
    /// layer to refresh. With nothing in the cloud yet, seed it from local instead. The handler the
    /// observer fires and the `setEnabled(true)` initial sync both land here.
    private func reconcile() async {
        guard enabled else { return }

        // "Nothing there yet" and "there is something there and we can't read it" used to share one
        // branch, whose else was `push()`. That meant a snapshot written by a newer version of the
        // app — or a truncated one — was silently overwritten with whatever this device happened to
        // hold. Only the genuinely-absent case may seed the cloud; an unreadable one is left exactly
        // as it stands, so the device that understands it can still fix it.
        guard let data = cloud.data(forKey: key) else {
            remoteUnreadable = false   // nothing there to protect
            await push()               // first device on this account → publish what we have
            return
        }
        guard let remote = try? JSONDecoder().decode(ConnectionSyncSnapshot.self, from: data) else {
            remoteUnreadable = true
            report(.failed(Self.unreadableRemote))
            return
        }
        remoteUnreadable = false
        guard let localSnapshot = try? await currentSnapshot() else {
            report(.failed("couldn't read the local connections file"))
            return
        }
        let merged = ConnectionSyncMerge.merge(local: localSnapshot, remote: remote)

        // If the merged result can't be written locally there is nothing to push and nothing to
        // repaint: pushing anyway would publish a state this device does not actually hold, and the
        // rail would reload to the unmerged list. Stop here instead, leaving the cloud untouched.
        do {
            try await local.replaceAll(connections: merged.connections, folders: merged.folders)
        } catch {
            report(.failed("couldn't save the merged connections locally"))
            return
        }
        meta = SyncMeta(
            connectionTombstones: merged.connectionTombstones,
            folderTombstones: merged.folderTombstones,
            connectionsOrderUpdatedAt: merged.connectionsOrderUpdatedAt,
            foldersOrderUpdatedAt: merged.foldersOrderUpdatedAt)
        // A lost sidecar costs tombstones (deleted records would resurrect on a later merge), which is
        // worth reporting, but the merge itself landed — so the rail still reloads below.
        var outcome = commit(merged)
        do {
            try persistMeta()
        } catch {
            if case .synced = outcome {
                outcome = .failed("synced, but couldn't save the local sync record")
            }
        }
        report(outcome)
        onRemoteChange?()
    }

    /// Hand an outcome to the App layer, which logs it and shows it in Settings.
    private func report(_ status: SyncStatus) {
        onStatusChange?(status)
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
