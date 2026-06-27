import Application
import Domain
import Foundation

/// On-disk adapter for the `ConnectionStore` port: a Codable JSON file under the user's
/// Application Support directory. Conforms to the same port as any future database-backed
/// store, so `CompositionRoot` can swap it without the use cases noticing. An actor gives us
/// free `Sendable` correctness and serializes the read-modify-write of the file.
///
/// The file holds both collections in one envelope — `{ "connections": [...], "folders": [...] }`
/// — so a connection and its folder persist together. A file written before folders existed is a
/// bare top-level `[Connection]` array; `loadStored` decodes that legacy shape as
/// connections-with-no-folders, and the next write upgrades it to the envelope.
public actor JSONFileConnectionStore: ConnectionStore {
    private let url: URL
    private var connectionCache: [Connection]?
    private var folderCache: [Folder]?

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/bosun/connections.json`.
    public static func defaultURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bosun", isDirectory: true)
        return support.appendingPathComponent("connections.json")
    }

    /// The persisted envelope. `folders` is a `var` with a default so a payload that predates the
    /// folders key still decodes; the legacy bare-array path is handled separately in `loadStored`.
    private struct Stored: Codable {
        var connections: [Connection]
        var folders: [Folder] = []
    }

    // MARK: Connections

    public func all() throws -> [Connection] {
        try loadStored().connections
    }

    public func save(_ connection: Connection) throws {
        var list = try all()
        if let idx = list.firstIndex(where: { $0.id == connection.id }) {
            list[idx] = connection
        } else {
            list.append(connection)
        }
        try persist(connections: list, folders: try folders())
    }

    public func delete(id: UUID) throws {
        let list = try all().filter { $0.id != id }
        try persist(connections: list, folders: try folders())
    }

    public func reorder(_ orderedIDs: [UUID]) throws {
        let list = try all()
        try persist(connections: Self.applyOrder(orderedIDs, to: list, id: \.id),
                    folders: try folders())
    }

    // MARK: Folders

    public func folders() throws -> [Folder] {
        try loadStored().folders
    }

    public func saveFolder(_ folder: Folder) throws {
        var list = try folders()
        if let idx = list.firstIndex(where: { $0.id == folder.id }) {
            list[idx] = folder
        } else {
            list.append(folder)
        }
        try persist(connections: try all(), folders: list)
    }

    public func deleteFolder(id: UUID) throws {
        // Drop only the folder record. Members' `folderId` may dangle, but `ConnectionGrouping`
        // reads a dangling reference as ungrouped, and the cascade (deleting members) is the use
        // case's job — the adapter stays a dumb persistence seam.
        let list = try folders().filter { $0.id != id }
        try persist(connections: try all(), folders: list)
    }

    public func reorderFolders(_ orderedIDs: [UUID]) throws {
        let list = try folders()
        try persist(connections: try all(),
                    folders: Self.applyOrder(orderedIDs, to: list, id: \.id))
    }

    // MARK: Bulk

    /// Overwrite both collections wholesale, bypassing the per-record upsert. The iCloud sync
    /// decorator (`UbiquitousConnectionStore`) uses this to apply a merge result in one atomic write
    /// — the normal use cases never call it (they go through `save`/`delete`/`reorder`).
    public func replaceAll(connections: [Connection], folders: [Folder]) throws {
        try persist(connections: connections, folders: folders)
    }

    // MARK: Storage

    /// Re-sort `items` into `orderedIDs`; any item the order omits keeps its current relative
    /// position at the end. Shared by `reorder` and `reorderFolders`.
    private static func applyOrder<T>(_ orderedIDs: [UUID], to items: [T], id: (T) -> UUID) -> [T] {
        let byID = Dictionary(items.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var result = orderedIDs.compactMap { byID[$0] }
        let named = Set(orderedIDs)
        result.append(contentsOf: items.filter { !named.contains(id($0)) })
        return result
    }

    /// Read the file into both caches, decoding the current envelope shape and falling back to the
    /// legacy bare `[Connection]` array (folders = []). A missing file is an empty store.
    private func loadStored() throws -> Stored {
        if let connectionCache { return Stored(connections: connectionCache, folders: folderCache ?? []) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            connectionCache = []
            folderCache = []
            return Stored(connections: [], folders: [])
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let stored: Stored
        if let envelope = try? decoder.decode(Stored.self, from: data) {
            stored = envelope
        } else {
            // Legacy: a bare top-level array of connections, written before folders existed.
            let connections = try decoder.decode([Connection].self, from: data)
            stored = Stored(connections: connections, folders: [])
        }
        connectionCache = stored.connections
        folderCache = stored.folders
        return stored
    }

    private func persist(connections: [Connection], folders: [Folder]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Stored(connections: connections, folders: folders))
        try data.write(to: url, options: .atomic)
        connectionCache = connections
        folderCache = folders
    }
}
