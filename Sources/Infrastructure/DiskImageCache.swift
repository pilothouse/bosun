import CryptoKit
import Domain
import Foundation

/// On-disk byte cache for avatar images, keyed by URL. GitHub avatar URLs are content-versioned
/// (`…/u/1?v=4`), so the URL is a permanent key that never needs time-based expiry — the cache
/// instead bounds its own footprint with an LRU size cap (`AvatarCacheEviction`). Deals only in raw
/// `Data`; decoding to `NSImage` (AppKit) stays in the App-layer `AvatarLoader`, keeping this
/// adapter framework-thin.
///
/// An `actor` like `JSONFileGitHubCacheStore`: free `Sendable` correctness and serialized I/O.
/// Best-effort and non-throwing throughout — the cache is an optimization that must never crash the
/// app or block a live fetch, so every failure degrades to a miss.
public actor DiskImageCache {
    private let directory: URL
    private let maxBytes: Int
    private var writesSinceTrim = 0
    /// Amortize the directory-enumeration cost of `trim()` — sweep once every this-many writes rather
    /// than on each store. A cold launch that fetches dozens of avatars trims a couple of times, not
    /// dozens.
    private let trimEvery = 32

    public init(directory: URL, maxBytes: Int = 50 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// `~/Library/Application Support/bosun/avatars/` — the `avatars` subdirectory beside
    /// `github-cache.json` / `connections.json` (same base dir the JSON stores compute).
    public static func defaultDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bosun", isDirectory: true)
            .appendingPathComponent("avatars", isDirectory: true)
    }

    /// Cached bytes for `url`, or `nil` on a miss / unreadable file. On a hit, bumps the file's
    /// modification date to now so the LRU trim keeps hot avatars: `atime` is unreliable under
    /// `relatime`/`noatime`, so the modification date is our LRU signal and we advance it on read.
    public func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    /// Writes `data` for `url` (best-effort, atomic), creating the directory on first use. Trims
    /// opportunistically every `trimEvery` writes so the folder can't grow unbounded within a session.
    public func store(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: url), options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= trimEvery {
            writesSinceTrim = 0
            trim()
        }
    }

    /// Enumerates the cache directory and deletes the least-recently-used files until the total size
    /// is within `maxBytes`, per `AvatarCacheEviction`. Best-effort; also called once at launch.
    public func trim() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        let entries: [AvatarCacheEviction.Entry] = files.map { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return AvatarCacheEviction.Entry(
                key: file.lastPathComponent,
                sizeBytes: values?.fileSize ?? 0,
                lastAccess: values?.contentModificationDate ?? .distantPast)
        }

        let evict = Set(AvatarCacheEviction.keysToEvict(entries: entries, maxBytes: maxBytes))
        guard !evict.isEmpty else { return }
        for file in files where evict.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(Self.filename(for: url))
    }

    /// SHA-256 hex of the absolute URL string + `.img`. Stable per content-versioned URL, so a hit is
    /// deterministic and a bumped `?v=` naturally lands on a fresh filename. `internal` (not `public`)
    /// so tests can target a specific file behind the opaque name via `@testable import`.
    static func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }
}
