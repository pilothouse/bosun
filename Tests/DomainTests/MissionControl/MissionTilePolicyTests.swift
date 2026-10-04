import XCTest
@testable import Domain

/// Contract tests for `MissionTilePolicy`: which tiles show, how they group into lanes, and how
/// focus moves.
final class MissionTilePolicyTests: XCTestCase {

    private let tiles = [
        MissionTile(id: "a", title: "a", activity: .working, repoKey: "o/x"),
        MissionTile(id: "b", title: "b", activity: .idle),
        MissionTile(id: "c", title: "c", activity: .attention, repoKey: "o/y"),
        MissionTile(id: "d", title: "d", activity: .working, repoKey: "o/y"),
    ]

    func testBellWinsOverBusy() {
        XCTAssertEqual(MissionTilePolicy.activity(busy: true, bell: true), .attention)
        XCTAssertEqual(MissionTilePolicy.activity(busy: true, bell: false), .working)
        XCTAssertEqual(MissionTilePolicy.activity(busy: false, bell: false), .idle)
    }

    func testAllFilterWithoutScopeKeepsEveryTileInOrder() {
        let ids = MissionTilePolicy.visible(tiles, filter: .all, repoKey: nil).map(\.id)
        XCTAssertEqual(ids, ["a", "b", "c", "d"])
    }

    func testWorkingFilterKeepsOnlyWorkingTiles() {
        let ids = MissionTilePolicy.visible(tiles, filter: .working, repoKey: nil).map(\.id)
        XCTAssertEqual(ids, ["a", "d"])
    }

    func testAttentionFilterKeepsOnlyAttentionTiles() {
        let ids = MissionTilePolicy.visible(tiles, filter: .attention, repoKey: nil).map(\.id)
        XCTAssertEqual(ids, ["c"])
    }

    func testRepoScopeDropsUnlinkedAndOtherRepos() {
        let ids = MissionTilePolicy.visible(tiles, filter: .all, repoKey: "o/y").map(\.id)
        XCTAssertEqual(ids, ["c", "d"])
    }

    func testFocusStaysOnAVisibleTile() {
        XCTAssertEqual(MissionTilePolicy.focusAfterFilter(current: "b", visible: ["a", "b"]), "b")
    }

    func testFocusFallsBackToFirstVisibleWhenFilteredOut() {
        XCTAssertEqual(MissionTilePolicy.focusAfterFilter(current: "z", visible: ["a", "b"]), "a")
        XCTAssertNil(MissionTilePolicy.focusAfterFilter(current: "z", visible: []))
    }

    func testOrderedByRepoFollowsRepoOrderAndPutsUnlinkedLast() {
        let ids = MissionTilePolicy.orderedByRepo(tiles, repoOrder: ["o/y", "o/x"]).map(\.id)
        XCTAssertEqual(ids, ["c", "d", "a", "b"])
    }

    func testOrderedByRepoAppendsReposMissingFromOrder() {
        let ids = MissionTilePolicy.orderedByRepo(tiles, repoOrder: ["o/y"]).map(\.id)
        XCTAssertEqual(ids, ["c", "d", "a", "b"])
    }

    func testCountsPerFilterBucket() {
        let counts = MissionTilePolicy.counts(tiles)
        XCTAssertEqual(counts.all, 4)
        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.attention, 1)
    }

    func testCycleWrapsBothWays() {
        XCTAssertEqual(MissionTilePolicy.cycle(focus: 3, delta: 1, count: 4), 0)
        XCTAssertEqual(MissionTilePolicy.cycle(focus: 0, delta: -1, count: 4), 3)
        XCTAssertEqual(MissionTilePolicy.cycle(focus: 5, delta: 0, count: 0), 0)
    }

    func testClampFocusKeepsIndexInRange() {
        XCTAssertEqual(MissionTilePolicy.clampFocus(9, count: 3), 2)
        XCTAssertEqual(MissionTilePolicy.clampFocus(-1, count: 3), 0)
    }
}
