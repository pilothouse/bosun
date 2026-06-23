import AppKit

/// Loads and caches avatar/org-icon images for `AvatarView`. Presentation-only glue (no business
/// rule), so it lives in Bosun (the App layer) rather than behind an Application port — see CLAUDE.md's "light
/// path": fetching bytes and caching an `NSImage` has nothing to unit-test and `NSImage`/`NSCache`
/// are AppKit-only anyway.
///
/// Deliberately a `@MainActor` class, not an `actor`: the panels rebuild their whole view tree on
/// every `layout()`, recreating each `AvatarView`. A cache *hit* must therefore be readable
/// synchronously inside `AvatarView.init` — otherwise the placeholder initials would flash on every
/// relayout and resize-drag frame while an `await` round-trips. `NSCache` is itself thread-safe, so
/// the synchronous read is safe; only the network fetch + decode happen off-main.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession
    /// URLs whose fetch is in flight, mapped to the views' completion closures. Coalesces the
    /// thundering herd of identical requests a rapid resize-drag would otherwise spawn before the
    /// first response lands; the first completion populates the cache and every later relayout hits
    /// the synchronous path. Holds only closures (which capture their view weakly), never views.
    private var inFlight: [URL: [(NSImage) -> Void]] = [:]
    /// URLs that resolved to a non-image / error, so we don't re-request a known-bad avatar on every
    /// relayout (the placeholder initials stay).
    private var failed: Set<URL> = []

    init(session: URLSession = .shared) {
        self.session = session
        cache.countLimit = 200   // bound memory; an evicted image just reloads (one initials flash)
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
            let image = await Self.fetch(url, session: session)
            let waiters = inFlight.removeValue(forKey: url) ?? []
            if let image {
                cache.setObject(image, forKey: url as NSURL)
                waiters.forEach { $0(image) }
            } else {
                failed.insert(url)
            }
        }
    }

    /// Off the main actor: `URLSession.data` suspends without blocking the UI and `NSImage(data:)`
    /// decodes in this async context. We only *construct* the image here — assigning it to a layer
    /// happens back on `@MainActor` in the caller.
    nonisolated private static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return NSImage(data: data)
    }
}
