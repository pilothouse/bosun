import XCTest
@testable import Domain

/// Contract tests for the pure avatar-cache eviction rule: given the files on disk (size + last
/// access) and a byte budget, it names the keys to delete — least-recently-used first — so the
/// folder can't grow unbounded. No I/O here; the Infrastructure `DiskImageCache` does the deleting.
final class AvatarCacheEvictionTests: XCTestCase {
    private func entry(_ key: String, size: Int, access: TimeInterval) -> AvatarCacheEviction.Entry {
        AvatarCacheEviction.Entry(key: key, sizeBytes: size, lastAccess: Date(timeIntervalSince1970: access))
    }

    func testUnderBudgetEvictsNothing() {
        let entries = [entry("a", size: 10, access: 1), entry("b", size: 20, access: 2)]
        XCTAssertEqual(AvatarCacheEviction.keysToEvict(entries: entries, maxBytes: 100), [])
    }

    func testExactlyAtBudgetEvictsNothing() {
        let entries = [entry("a", size: 40, access: 1), entry("b", size: 60, access: 2)]
        XCTAssertEqual(AvatarCacheEviction.keysToEvict(entries: entries, maxBytes: 100), [])
    }

    func testEvictsOldestAccessFirstUntilUnderBudget() {
        // 30+30+30 = 90 over a 50-byte budget. Drop oldest ("a") → 60, still over; drop next ("b") →
        // 30, under. "c" (newest) survives.
        let entries = [
            entry("b", size: 30, access: 20),
            entry("c", size: 30, access: 30),
            entry("a", size: 30, access: 10)
        ]
        XCTAssertEqual(AvatarCacheEviction.keysToEvict(entries: entries, maxBytes: 50), ["a", "b"])
    }

    func testStopsAsSoonAsUnderBudget() {
        // Dropping just the oldest is enough — don't over-evict.
        let entries = [
            entry("old", size: 60, access: 1),
            entry("new", size: 30, access: 2)
        ]
        XCTAssertEqual(AvatarCacheEviction.keysToEvict(entries: entries, maxBytes: 50), ["old"])
    }

    func testSingleFileLargerThanWholeBudgetIsEvicted() {
        let entries = [entry("huge", size: 200, access: 1)]
        XCTAssertEqual(AvatarCacheEviction.keysToEvict(entries: entries, maxBytes: 100), ["huge"])
    }

    func testEmptyInputEvictsNothing() {
        XCTAssertEqual(AvatarCacheEviction.keysToEvict(entries: [], maxBytes: 100), [])
    }
}
