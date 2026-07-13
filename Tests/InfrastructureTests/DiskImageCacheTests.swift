import XCTest
@testable import Domain
@testable import Infrastructure

/// Contract tests for the on-disk avatar byte cache: it round-trips bytes keyed by URL, survives
/// across instances (the "avatars survive restart" criterion), keys a content-versioned URL to a
/// stable filename (and a bumped `?v=` to a new one), treats a miss/garbage file as a non-crashing
/// miss, and self-trims to a byte budget by evicting least-recently-used files. Mirrors
/// `JSONFileGitHubCacheStoreTests`' temp-dir setup so nothing touches the real Application Support dir.
final class DiskImageCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-avatar-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func cache(maxBytes: Int = 50 * 1024 * 1024) -> DiskImageCache {
        DiskImageCache(directory: dir, maxBytes: maxBytes)
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testStoreThenReadRoundTripsBytes() async {
        let sut = cache()
        let bytes = Data([0x1, 0x2, 0x3, 0x4])
        await sut.store(bytes, for: url("https://avatars.githubusercontent.com/u/1?v=4"))
        let read = await sut.data(for: url("https://avatars.githubusercontent.com/u/1?v=4"))
        XCTAssertEqual(read, bytes)
    }

    func testFreshInstanceReadsBytesWrittenByAPriorInstance() async {
        // Proves cross-launch persistence: a second cold `DiskImageCache` over the same directory
        // reads what the first one wrote — no in-memory state carried over.
        let writer = cache()
        let bytes = Data("png-ish".utf8)
        let target = url("https://avatars.githubusercontent.com/u/42?v=4")
        await writer.store(bytes, for: target)

        let reader = cache()
        let read = await reader.data(for: target)
        XCTAssertEqual(read, bytes)
    }

    func testMissReturnsNil() async {
        let sut = cache()
        let read = await sut.data(for: url("https://avatars.githubusercontent.com/u/never?v=1"))
        XCTAssertNil(read)
    }

    func testDistinctURLsGetDistinctFiles() async throws {
        let sut = cache()
        await sut.store(Data("a".utf8), for: url("https://avatars.githubusercontent.com/u/1?v=4"))
        await sut.store(Data("b".utf8), for: url("https://avatars.githubusercontent.com/u/2?v=4"))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
    }

    func testBumpedVersionQueryIsANewKeyLeavingTheOldFileInPlace() async throws {
        // When an avatar changes, GitHub bumps `?v=`. The new URL must fetch & cache under a new key;
        // the old file stays until a trim reclaims it.
        let sut = cache()
        let v4 = url("https://avatars.githubusercontent.com/u/7?v=4")
        let v5 = url("https://avatars.githubusercontent.com/u/7?v=5")
        await sut.store(Data("old".utf8), for: v4)
        await sut.store(Data("new".utf8), for: v5)

        let readV4 = await sut.data(for: v4)
        let readV5 = await sut.data(for: v5)
        XCTAssertEqual(readV4, Data("old".utf8))
        XCTAssertEqual(readV5, Data("new".utf8))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2, "a bumped ?v= is a separate key, not an overwrite")
    }

    func testGarbageFileDoesNotCrashAndReturnsItsBytes() async {
        // A truncated/garbage cache file is still readable bytes here; decode failure (→ network
        // refetch, then monogram) is the loader's concern, not the byte cache's.
        let sut = cache()
        let junk = Data([0xff, 0x00, 0xff])
        let target = url("https://avatars.githubusercontent.com/u/9?v=4")
        await sut.store(junk, for: target)
        let read = await sut.data(for: target)
        XCTAssertEqual(read, junk)
    }

    func testTrimEvictsLeastRecentlyUsedUntilUnderBudget() async throws {
        // Budget = 250 bytes; three 100-byte files = 300 over budget. Stamp each file with an explicit
        // modification date (the LRU signal) so "oldest" is deterministic, then trim: the oldest file
        // goes, the two newest (200 bytes total ≤ 250) survive.
        let sut = cache(maxBytes: 250)
        let payload = Data(count: 100)
        let old = url("https://avatars.githubusercontent.com/u/old?v=1")
        let mid = url("https://avatars.githubusercontent.com/u/mid?v=1")
        let new = url("https://avatars.githubusercontent.com/u/new?v=1")
        await sut.store(payload, for: old)
        await sut.store(payload, for: mid)
        await sut.store(payload, for: new)

        try setModificationDate(old, 1_000)
        try setModificationDate(mid, 2_000)
        try setModificationDate(new, 3_000)

        await sut.trim()

        let evictedOld = await sut.data(for: old)
        let keptMid = await sut.data(for: mid)
        let keptNew = await sut.data(for: new)
        XCTAssertNil(evictedOld, "least-recently-used file should be evicted")
        XCTAssertNotNil(keptMid)
        XCTAssertNotNil(keptNew)
    }

    // Stamp a specific URL's on-disk file with a modification date so LRU ordering is deterministic.
    // Uses the cache's own URL→filename hashing (internal, exposed via `@testable`) to target the
    // exact file behind an opaque hashed name.
    private func setModificationDate(_ url: URL, _ time: TimeInterval) throws {
        let file = dir.appendingPathComponent(DiskImageCache.filename(for: url))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: file.path)
    }
}
