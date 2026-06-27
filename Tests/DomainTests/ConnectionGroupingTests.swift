import XCTest
@testable import Domain

/// Contract tests for the pure connection-grouping rule. They describe what `ConnectionGrouping`
/// promises outward — Favorites (pinned, when any) → one section per folder in array order (empty
/// folders included) → Ungrouped (when any) — not how it buckets. Don't edit a contract test to
/// make an implementation pass; if the contract is wrong, flag it.
final class ConnectionGroupingTests: XCTestCase {

    private func conn(_ name: String, favorite: Bool = false, folder: UUID? = nil) -> Connection {
        Connection(id: UUID(), name: name, kind: .ssh(host: "h", port: 22, user: nil),
                   isFavorite: favorite, folderId: folder)
    }

    func testNoFoldersYieldsAFlatUngroupedSection() {
        let a = conn("a"), b = conn("b")
        let sections = ConnectionGrouping.sections(connections: [a, b], folders: [])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.kind, .ungrouped)
        XCTAssertEqual(sections.first?.connections.map(\.id), [a.id, b.id])
    }

    func testFavoritesArePinnedFirstAndStillAppearInTheirBucket() {
        let fav = conn("fav", favorite: true)
        let plain = conn("plain")
        let sections = ConnectionGrouping.sections(connections: [fav, plain], folders: [])
        XCTAssertEqual(sections.map(\.kind), [.favorites, .ungrouped])
        XCTAssertEqual(sections[0].connections.map(\.id), [fav.id], "favorites pinned first")
        XCTAssertEqual(sections[1].connections.map(\.id), [fav.id, plain.id],
                       "a favorite is a pin, not a move — it still shows in Ungrouped")
    }

    func testOneSectionPerFolderInArrayOrderIncludingEmptyFolders() {
        let f1 = Folder(id: UUID(), name: "one")
        let f2 = Folder(id: UUID(), name: "two")          // deliberately left empty
        let inOne = conn("inOne", folder: f1.id)
        let loose = conn("loose")
        let sections = ConnectionGrouping.sections(connections: [inOne, loose], folders: [f1, f2])
        XCTAssertEqual(sections.map(\.kind), [.folder(f1), .folder(f2), .ungrouped])
        XCTAssertEqual(sections[0].connections.map(\.id), [inOne.id])
        XCTAssertEqual(sections[1].connections, [], "an empty folder is still a section (drop target)")
        XCTAssertEqual(sections[2].connections.map(\.id), [loose.id])
    }

    func testArrayOrderIsPreservedWithinAFolder() {
        let f = Folder(id: UUID(), name: "f")
        let a = conn("a", folder: f.id), b = conn("b", folder: f.id), c = conn("c", folder: f.id)
        // Global order [c, a, b] must survive as the in-folder order.
        let sections = ConnectionGrouping.sections(connections: [c, a, b], folders: [f])
        XCTAssertEqual(sections.first?.connections.map(\.id), [c.id, a.id, b.id])
    }

    func testDanglingFolderIdFallsIntoUngrouped() {
        // A connection points at a folder that no longer exists — it must not vanish.
        let orphan = conn("orphan", folder: UUID())
        let sections = ConnectionGrouping.sections(connections: [orphan], folders: [])
        XCTAssertEqual(sections.map(\.kind), [.ungrouped])
        XCTAssertEqual(sections.first?.connections.map(\.id), [orphan.id])
    }

    func testEmptyUngroupedIsOmittedWhenEverythingIsFiled() {
        let f = Folder(id: UUID(), name: "f")
        let only = conn("only", folder: f.id)
        let sections = ConnectionGrouping.sections(connections: [only], folders: [f])
        XCTAssertEqual(sections.map(\.kind), [.folder(f)], "no empty Ungrouped section")
    }
}
