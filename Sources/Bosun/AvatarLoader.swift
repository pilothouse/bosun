import AppKit
import Infrastructure

/// Loads and caches avatar/org-icon images for `AvatarView`. App-layer glue: it owns the in-memory
/// `NSCache<NSURL, NSImage>` and the AppKit decode, and layers an on-disk byte cache
/// (`Infrastructure.DiskImageCache`) underneath so avatars survive restarts and background refreshes
/// don't re-download unchanged images. The testable pieces live inward per CLAUDE.md — the disk I/O
/// in `DiskImageCache`, the LRU eviction rule in `Domain.AvatarCacheEviction` — leaving this class
/// as thin `NSImage`/`NSCache` wiring the App layer can't unit-test anyway.
///
/// Deliberately a `@MainActor` class, not an `actor`: the panels rebuild their whole view tree on
/// every `layout()`, recreating each `AvatarView`. A cache *hit* must therefore be readable
/// synchronously inside `AvatarView.init` — otherwise the placeholder initials would flash on every
/// relayout and resize-drag frame while an `await` round-trips. `NSCache` is itself thread-safe, so
/// the synchronous read is safe; only the disk read, network fetch, and decode happen off-main.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession
    /// Persistent byte cache keyed by URL. GitHub avatar URLs are content-versioned (`…?v=4`), so a
    /// hit never needs revalidation and a changed avatar lands on a fresh key on its own.
    private let disk: DiskImageCache
    /// URLs whose fetch is in flight, mapped to the views' completion closures. Coalesces the
    /// thundering herd of identical requests a rapid resize-drag would otherwise spawn before the
    /// first response lands; the first completion populates the cache and every later relayout hits
    /// the synchronous path. Holds only closures (which capture their view weakly), never views.
    private var inFlight: [URL: [(NSImage) -> Void]] = [:]
    /// URLs that resolved to a non-image / error, so we don't re-request a known-bad avatar on every
    /// relayout (the placeholder initials stay).
    private var failed: Set<URL> = []

    init(session: URLSession = .shared,
         disk: DiskImageCache = DiskImageCache(directory: DiskImageCache.defaultDirectory())) {
        self.session = session
        self.disk = disk
        cache.countLimit = 200   // bound memory; an evicted image just reloads from disk (one flash)
        Task { await disk.trim() }   // reclaim any over-budget files left by a prior run, at launch
    }

    /// Synchronous cache read — the no-flicker path used inside `AvatarView.init`.
    func cachedImage(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// Loads `url`, calling `completion` on the main thread once. A cache hit calls back
    /// immediately; otherwise the placeholder stays until the image arrives. Failures are silent
    /// (the caller keeps showing initials).
    func load(_ url: URL, completion: @escaping (NSImage) -> Void) {
        if let hit = cache.object(forKey: url as NSURL) { completion(hit); return }
        if failed.contains(url) { return }
        if inFlight[url] != nil { inFlight[url]?.append(completion); return }
        inFlight[url] = [completion]

        Task { @MainActor in
            let image = await Self.resolve(url, disk: disk, session: session)
            let waiters = inFlight.removeValue(forKey: url) ?? []
            if let image {
                cache.setObject(image, forKey: url as NSURL)
                waiters.forEach { $0(image) }
            } else {
                failed.insert(url)
            }
        }
    }

    /// Off the main actor: resolve the image from disk first, then the network. `DiskImageCache.data`
    /// and `URLSession.data` both suspend without blocking the UI, and `NSImage(data:)` decodes in
    /// this async context. On a network hit the raw bytes are written to disk so the next launch
    /// reads them without a fetch. We only *construct* the image here — assigning it to a layer
    /// happens back on `@MainActor` in the caller. A corrupt disk file simply fails to decode and
    /// falls through to the network (then the caller's monogram), so it degrades gracefully.
    nonisolated private static func resolve(_ url: URL, disk: DiskImageCache,
                                            session: URLSession) async -> NSImage? {
        if let data = await disk.data(for: url), let image = NSImage(data: data) { return image }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let image = NSImage(data: data) else { return nil }
        await disk.store(data, for: url)
        return image
    }
}
