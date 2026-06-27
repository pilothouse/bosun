import Application
import Domain
import Foundation

/// On-disk adapter for the `ConnectionStore` port: a Codable JSON file under the user's
/// Application Support directory. Conforms to the same port as any future database-backed
/// store, so `CompositionRoot` can swap it without the use cases noticing. An actor gives us
/// free `Sendable` correctness and serializes the read-modify-write of the file.
public actor JSONFileConnectionStore: ConnectionStore {
    private let url: URL
    private var cache: [Connection]?

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

    public func all() throws -> [Connection] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: url)
        let list = try JSONDecoder().decode([Connection].self, from: data)
        cache = list
        return list
    }

    public func save(_ connection: Connection) throws {
        var list = try all()
        if let idx = list.firstIndex(where: { $0.id == connection.id }) {
            list[idx] = connection
        } else {
            list.append(connection)
        }
        try persist(list)
    }

    public func delete(id: UUID) throws {
        var list = try all()
        list.removeAll { $0.id == id }
        try persist(list)
    }

    public func reorder(_ orderedIDs: [UUID]) throws {
        let list = try all()
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = orderedIDs.compactMap { byID[$0] }
        // Defensive: keep any stored connection the order omits, in its current relative order.
        let named = Set(orderedIDs)
        result.append(contentsOf: list.filter { !named.contains($0.id) })
        try persist(result)
    }

    private func persist(_ list: [Connection]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(list)
        try data.write(to: url, options: .atomic)
        cache = list
    }
}
