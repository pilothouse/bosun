import Application
import Domain
import Foundation

/// On-disk adapter for the `GitHubCacheStore` port: the viewer's GitHub data as one Codable JSON
/// snapshot under Application Support, mirroring `JSONFileConnectionStore` (an actor for free
/// `Sendable` correctness + a serialized read-modify-write, plus an in-memory mirror so reads after
/// the first don't touch disk). Unlike the connection store it is **best-effort and non-throwing**
/// like the preferences adapter: a missing or corrupt file reads as an empty snapshot, and a failed
/// write is dropped — the cache is an optimization that must never crash the app or block a live
/// fetch.
public actor JSONFileGitHubCacheStore: GitHubCacheStore {
    private let url: URL
    private var snapshot: Snapshot?

    /// The whole cache as one value. `login` scopes the data so a different account's rows are never
    /// shown; `items` is keyed by `repoKey#kind` (see `itemsKey`).
    private struct Snapshot: Codable {
        var login: String?
        var orgs: [GitHubOrg]
        var viewerRepos: [GitHubRepo]
        var items: [String: [GitHubItem]]

        static let empty = Snapshot(login: nil, orgs: [], viewerRepos: [], items: [:])
    }

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/bosun/github-cache.json` — the same directory as
    /// `connections.json`.
    public static func defaultURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bosun", isDirectory: true)
        return support.appendingPathComponent("github-cache.json")
    }

    // MARK: - Reads

    public func cachedLogin() async -> String? { loaded().login }
    public func loadOrgs() async -> [GitHubOrg] { loaded().orgs }
    public func loadViewerRepos() async -> [GitHubRepo] { loaded().viewerRepos }

    public func loadItems(repoKey: String, kind: GitHubItemKind) async -> [GitHubItem] {
        loaded().items[Self.itemsKey(repoKey: repoKey, kind: kind)] ?? []
    }

    // MARK: - Writes

    public func saveOrgs(_ orgs: [GitHubOrg], viewerRepos: [GitHubRepo], login: String) async {
        var current = loaded()
        // A different signed-in user means the cached items belong to another account — drop them.
        if current.login != login { current = .empty }
        current.login = login
        current.orgs = orgs
        current.viewerRepos = viewerRepos
        persist(current)
    }

    public func saveItems(_ items: [GitHubItem], repoKey: String, kind: GitHubItemKind) async {
        var current = loaded()
        current.items[Self.itemsKey(repoKey: repoKey, kind: kind)] = items
        persist(current)
    }

    public func clear() async {
        snapshot = .empty
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Disk

    /// The in-memory mirror, populated from disk on first use. A missing or unreadable/corrupt file
    /// is a cache miss, not an error — it reads as empty so the caller just falls back to a live fetch.
    private func loaded() -> Snapshot {
        if let snapshot { return snapshot }
        let loaded: Snapshot
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            loaded = decoded
        } else {
            loaded = .empty
        }
        snapshot = loaded
        return loaded
    }

    /// Update the mirror, then best-effort atomic write — a failure leaves the mirror correct for
    /// this session and simply means the next launch starts cold.
    private func persist(_ value: Snapshot) {
        snapshot = value
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func itemsKey(repoKey: String, kind: GitHubItemKind) -> String {
        "\(repoKey)#\(kind.rawValue)"
    }
}
