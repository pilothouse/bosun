import Foundation

/// The "which files do we drop?" rule for the on-disk avatar cache. Avatar URLs are
/// content-versioned (`…?v=4`), so keys never expire by time — instead the folder is bounded by a
/// byte budget and this rule picks the least-recently-used entries to evict when the budget is
/// exceeded. Pure and I/O-free: the Infrastructure `DiskImageCache` gathers the entries off disk,
/// calls this, and deletes what it names. Lives in Domain because it's a rule with an `if` that both
/// the write-time and launch-time trims share.
public enum AvatarCacheEviction {
    /// One file in the cache directory. `lastAccess` is the LRU signal (the store bumps it on a hit).
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let sizeBytes: Int
        public let lastAccess: Date

        public init(key: String, sizeBytes: Int, lastAccess: Date) {
            self.key = key
            self.sizeBytes = sizeBytes
            self.lastAccess = lastAccess
        }
    }

    /// Keys to delete so the total on-disk size drops to `maxBytes` or below, evicting
    /// least-recently-accessed first and stopping the moment the budget is met (never over-evicts).
    /// Returns `[]` when already within budget.
    public static func keysToEvict(entries: [Entry], maxBytes: Int) -> [String] {
        var running = entries.reduce(0) { $0 + $1.sizeBytes }
        guard running > maxBytes else { return [] }

        var evict: [String] = []
        for entry in entries.sorted(by: { $0.lastAccess < $1.lastAccess }) where running > maxBytes {
            evict.append(entry.key)
            running -= entry.sizeBytes
        }
        return evict
    }
}
