import Foundation

/// A deletion record: the id that was removed and when. Tombstones are how a delete survives a merge
/// — without one, a record still present on the other device would simply reappear on the next sync.
/// A re-create stamped *after* the tombstone wins (the record comes back); see `ConnectionSyncMerge`.
public struct Tombstone: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let deletedAt: Date

    public init(id: UUID, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// The full connection + folder state plus the metadata a per-record merge needs: every record
/// carries its own `updatedAt`, deletions are tombstoned, and each collection's display order carries
/// one last-writer-wins timestamp. This is the payload that crosses the iCloud transport. Pure value
/// type — the I/O (KVS push/pull, local mirror) lives in Infrastructure; `ConnectionSyncMerge` below
/// is the pure rule that reconciles two snapshots.
public struct ConnectionSyncSnapshot: Sendable, Equatable, Codable {
    public var connections: [Connection]
    public var folders: [Folder]
    public var connectionTombstones: [Tombstone]
    public var folderTombstones: [Tombstone]
    /// When the *order* of connections last changed (a reorder, or a new record appended). The merge
    /// picks the more recent of the two snapshots as the order authority; `nil` is "oldest possible".
    public var connectionsOrderUpdatedAt: Date?
    public var foldersOrderUpdatedAt: Date?

    public init(connections: [Connection] = [], folders: [Folder] = [],
                connectionTombstones: [Tombstone] = [], folderTombstones: [Tombstone] = [],
                connectionsOrderUpdatedAt: Date? = nil, foldersOrderUpdatedAt: Date? = nil) {
        self.connections = connections
        self.folders = folders
        self.connectionTombstones = connectionTombstones
        self.folderTombstones = folderTombstones
        self.connectionsOrderUpdatedAt = connectionsOrderUpdatedAt
        self.foldersOrderUpdatedAt = foldersOrderUpdatedAt
    }
}

/// A record the merge can reconcile: identified by a `UUID` and stamped with an optional `updatedAt`.
/// Internal — both `Connection` and `Folder` conform so one generic merge serves both collections.
protocol TimestampedRecord: Identifiable where ID == UUID {
    var updatedAt: Date? { get }
}

extension Connection: TimestampedRecord {}
extension Folder: TimestampedRecord {}

/// Reconciles two `ConnectionSyncSnapshot`s into one — the v1 iCloud merge. Deterministic and pure
/// (no clock, no I/O), so it runs identically on either device and is fully unit-tested.
///
/// Per record: union by id, the newer `updatedAt` wins (`nil` = oldest; remote wins an exact tie so
/// the result is order-independent). Deletions: a tombstone removes a record when it post-dates the
/// record's last edit; an edit at-or-after the tombstone resurrects it (and the tombstone is dropped).
/// Order: the collection whose order changed most recently wins the sequence; records that exist only
/// on the other side append at the end (oldest edit first, id as a stable tiebreak). The whole thing
/// is null-safe — an empty or absent remote keeps local untouched, which also covers an iCloud
/// account change handing us a fresh (empty) store.
public enum ConnectionSyncMerge {
    public static func merge(local: ConnectionSyncSnapshot,
                             remote: ConnectionSyncSnapshot) -> ConnectionSyncSnapshot {
        let (connections, connectionTombstones) = mergeRecords(
            local: local.connections, remote: remote.connections,
            localTombstones: local.connectionTombstones, remoteTombstones: remote.connectionTombstones,
            localOrderAt: local.connectionsOrderUpdatedAt, remoteOrderAt: remote.connectionsOrderUpdatedAt)
        let (folders, folderTombstones) = mergeRecords(
            local: local.folders, remote: remote.folders,
            localTombstones: local.folderTombstones, remoteTombstones: remote.folderTombstones,
            localOrderAt: local.foldersOrderUpdatedAt, remoteOrderAt: remote.foldersOrderUpdatedAt)
        return ConnectionSyncSnapshot(
            connections: connections,
            folders: folders,
            connectionTombstones: connectionTombstones,
            folderTombstones: folderTombstones,
            connectionsOrderUpdatedAt: maxDate(local.connectionsOrderUpdatedAt, remote.connectionsOrderUpdatedAt),
            foldersOrderUpdatedAt: maxDate(local.foldersOrderUpdatedAt, remote.foldersOrderUpdatedAt))
    }

    private static func mergeRecords<T: TimestampedRecord>(
        local: [T], remote: [T],
        localTombstones: [Tombstone], remoteTombstones: [Tombstone],
        localOrderAt: Date?, remoteOrderAt: Date?
    ) -> ([T], [Tombstone]) {
        func stamp(_ record: T) -> Date { record.updatedAt ?? .distantPast }

        // 1. Tombstones: union by id, keeping the newest deletion.
        var tombByID: [UUID: Date] = [:]
        for tomb in localTombstones + remoteTombstones {
            tombByID[tomb.id] = Swift.max(tombByID[tomb.id] ?? .distantPast, tomb.deletedAt)
        }

        // 2. Records: union by id, the newest edit winning (remote wins an exact tie — we visit it last).
        var recordByID: [UUID: T] = [:]
        for record in local + remote {
            if let current = recordByID[record.id], stamp(current) > stamp(record) { continue }
            recordByID[record.id] = record
        }

        // 3. Apply tombstones: a deletion newer than the last edit removes the record and the
        //    tombstone survives; otherwise the record is a (re)creation and the tombstone is dropped.
        var survivors: [UUID: T] = [:]
        for (id, record) in recordByID {
            if let deletedAt = tombByID[id], deletedAt > stamp(record) { continue }
            survivors[id] = record
            tombByID[id] = nil
        }

        // 4. Order: the more recently reordered snapshot dictates the sequence; ids only on the other
        //    side append at the end. Remote wins only when strictly newer, so a tie keeps local order.
        let remoteOrderWins = (remoteOrderAt ?? .distantPast) > (localOrderAt ?? .distantPast)
        let authorityIDs = (remoteOrderWins ? remote : local).map(\.id)
        var ordered: [T] = []
        var placed = Set<UUID>()
        for id in authorityIDs {
            if let record = survivors[id] {
                ordered.append(record)
                placed.insert(id)
            }
        }
        let remaining = survivors.values
            .filter { !placed.contains($0.id) }
            .sorted { (stamp($0), $0.id.uuidString) < (stamp($1), $1.id.uuidString) }
        ordered.append(contentsOf: remaining)

        // 5. Surviving tombstones, sorted for a stable encoding.
        let tombstones = tombByID
            .map { Tombstone(id: $0.key, deletedAt: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        return (ordered, tombstones)
    }

    /// The later of two optional dates; `nil` counts as the oldest. Returns `nil` only when both are.
    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return Swift.max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}
