import XCTest
@testable import Domain

/// Contract tests for the pure iCloud merge rule. The merge is deterministic and clock-free, so each
/// case fixes explicit `updatedAt`/tombstone/order timestamps and asserts the reconciled snapshot —
/// the behavior that lets two devices converge without a live iCloud account in the loop.
final class ConnectionSyncMergeTests: XCTestCase {
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)
    private let t3 = Date(timeIntervalSince1970: 3_000)

    private func conn(_ id: UUID, _ name: String, at when: Date?) -> Connection {
        Connection(id: id, name: name, kind: .ssh(host: "h", port: 22, user: nil), updatedAt: when)
    }

    func testNewerEditWins_regardlessOfSide() {
        let id = UUID()
        let old = conn(id, "old", at: t1)
        let new = conn(id, "new", at: t2)

        let remoteNewer = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [old]),
            remote: ConnectionSyncSnapshot(connections: [new]))
        XCTAssertEqual(remoteNewer.connections.map(\.name), ["new"])

        let localNewer = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [new]),
            remote: ConnectionSyncSnapshot(connections: [old]))
        XCTAssertEqual(localNewer.connections.map(\.name), ["new"])
    }

    func testFirstSyncUnionsBothSides() {
        let a = conn(UUID(), "a", at: t1)
        let b = conn(UUID(), "b", at: t1)

        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [a]),
            remote: ConnectionSyncSnapshot(connections: [b]))

        XCTAssertEqual(Set(merged.connections.map(\.id)), [a.id, b.id])
    }

    func testTombstoneNewerThanEditDeletesRecord() {
        let id = UUID()
        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [conn(id, "live", at: t1)]),
            remote: ConnectionSyncSnapshot(connectionTombstones: [Tombstone(id: id, deletedAt: t2)]))

        XCTAssertTrue(merged.connections.isEmpty, "a delete newer than the last edit removes it")
        XCTAssertEqual(merged.connectionTombstones.map(\.id), [id], "tombstone is carried forward")
    }

    func testReCreateNewerThanTombstoneResurrectsRecord() {
        let id = UUID()
        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [conn(id, "back", at: t3)]),
            remote: ConnectionSyncSnapshot(connectionTombstones: [Tombstone(id: id, deletedAt: t2)]))

        XCTAssertEqual(merged.connections.map(\.name), ["back"], "an edit after the delete wins")
        XCTAssertTrue(merged.connectionTombstones.isEmpty, "the stale tombstone is dropped")
    }

    func testMoreRecentReorderWinsTheOrder() {
        let x = conn(UUID(), "x", at: t1)
        let y = conn(UUID(), "y", at: t1)

        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [x, y], connectionsOrderUpdatedAt: t1),
            remote: ConnectionSyncSnapshot(connections: [y, x], connectionsOrderUpdatedAt: t2))

        XCTAssertEqual(merged.connections.map(\.name), ["y", "x"], "newer reorder dictates the sequence")
        XCTAssertEqual(merged.connectionsOrderUpdatedAt, t2)
    }

    func testRecordOnlyOnOtherSideAppendsAfterTheAuthorityOrder() {
        let x = conn(UUID(), "x", at: t1)
        let z = conn(UUID(), "z", at: t1)

        // Local order is the authority (newer); z exists only remotely, so it lands at the end.
        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [x], connectionsOrderUpdatedAt: t2),
            remote: ConnectionSyncSnapshot(connections: [z], connectionsOrderUpdatedAt: t1))

        XCTAssertEqual(merged.connections.map(\.name), ["x", "z"])
    }

    func testEmptyRemoteKeepsLocalUntouched() {
        let a = conn(UUID(), "a", at: t1)
        let b = conn(UUID(), "b", at: t1)

        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(connections: [a, b], connectionsOrderUpdatedAt: t1),
            remote: ConnectionSyncSnapshot())

        XCTAssertEqual(merged.connections.map(\.name), ["a", "b"])
        XCTAssertTrue(merged.connectionTombstones.isEmpty)
    }

    func testFoldersMergeAndTombstoneSymmetrically() {
        let editedID = UUID()
        let deletedID = UUID()
        let merged = ConnectionSyncMerge.merge(
            local: ConnectionSyncSnapshot(folders: [
                Folder(id: editedID, name: "old name", updatedAt: t1),
                Folder(id: deletedID, name: "doomed", updatedAt: t1)
            ]),
            remote: ConnectionSyncSnapshot(
                folders: [Folder(id: editedID, name: "new name", updatedAt: t2)],
                folderTombstones: [Tombstone(id: deletedID, deletedAt: t2)]))

        XCTAssertEqual(merged.folders.map(\.id), [editedID], "deleted folder gone, edited folder kept")
        XCTAssertEqual(merged.folders.first?.name, "new name", "newer folder edit wins")
        XCTAssertEqual(merged.folderTombstones.map(\.id), [deletedID])
    }
}
