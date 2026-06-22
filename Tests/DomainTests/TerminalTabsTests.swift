import XCTest
@testable import Domain

/// Contract tests for the pure tab-strip model. They describe what `TerminalTabs` promises
/// outward — the ordering and "which tab is active now?" rules — not how it works inside.
/// Don't edit a contract test to make an implementation pass; if the contract is wrong, flag it.
final class TerminalTabsTests: XCTestCase {
    private func tabs(_ ids: String...) -> TerminalTabs<String> {
        var t = TerminalTabs<String>()
        for id in ids { t.open(id) }
        return t
    }

    func testStartsEmpty() {
        let t = TerminalTabs<String>()
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.activeID)
        XCTAssertEqual(t.count, 0)
        XCTAssertNil(t.activeIndex)
    }

    func testOpenAppendsAndActivates() {
        let t = tabs("a", "b")
        XCTAssertEqual(t.ids, ["a", "b"])
        XCTAssertEqual(t.activeID, "b")
        XCTAssertEqual(t.activeIndex, 1)
    }

    func testOpenExistingIdDoesNotDuplicateButActivates() {
        var t = tabs("a", "b")
        t.open("a")
        XCTAssertEqual(t.ids, ["a", "b"])
        XCTAssertEqual(t.activeID, "a")
    }

    func testSelectActivatesExistingAndIgnoresUnknown() {
        var t = tabs("a", "b", "c")
        t.select("a")
        XCTAssertEqual(t.activeID, "a")
        t.select("zzz")
        XCTAssertEqual(t.activeID, "a")
    }

    func testClosingInactiveKeepsActive() {
        var t = tabs("a", "b", "c")          // active c
        t.close("a")
        XCTAssertEqual(t.ids, ["b", "c"])
        XCTAssertEqual(t.activeID, "c")
    }

    func testClosingActiveMiddleActivatesTheTabThatShiftsIn() {
        var t = tabs("a", "b", "c")
        t.select("b")
        t.close("b")
        XCTAssertEqual(t.ids, ["a", "c"])
        XCTAssertEqual(t.activeID, "c")      // slot 1 now holds c
    }

    func testClosingActiveLastActivatesNewLast() {
        var t = tabs("a", "b", "c")          // active c (last)
        t.close("c")
        XCTAssertEqual(t.ids, ["a", "b"])
        XCTAssertEqual(t.activeID, "b")
    }

    func testClosingActiveFirstActivatesNewFirst() {
        var t = tabs("a", "b", "c")
        t.select("a")
        t.close("a")
        XCTAssertEqual(t.ids, ["b", "c"])
        XCTAssertEqual(t.activeID, "b")
    }

    func testClosingLastRemainingEmptiesAndClearsActive() {
        var t = tabs("a")
        let next = t.close("a")
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.activeID)
        XCTAssertNil(next)
    }

    func testClosingUnknownIsNoOp() {
        var t = tabs("a", "b")
        t.close("zzz")
        XCTAssertEqual(t.ids, ["a", "b"])
        XCTAssertEqual(t.activeID, "b")
    }

    func testGotoNextWraps() {
        var t = tabs("a", "b", "c")          // active c
        t.goto(.next)
        XCTAssertEqual(t.activeID, "a")
    }

    func testGotoPreviousWraps() {
        var t = tabs("a", "b", "c")
        t.select("a")
        t.goto(.previous)
        XCTAssertEqual(t.activeID, "c")
    }

    func testGotoLast() {
        var t = tabs("a", "b", "c")
        t.select("a")
        t.goto(.last)
        XCTAssertEqual(t.activeID, "c")
    }

    func testGotoIndexIsOneBased() {
        var t = tabs("a", "b", "c")
        t.goto(.index(2))
        XCTAssertEqual(t.activeID, "b")
    }

    func testGotoIndexOutOfRangeIsNoOp() {
        var t = tabs("a", "b", "c")          // active c
        t.goto(.index(99))
        XCTAssertEqual(t.activeID, "c")
    }

    func testGotoOnEmptyIsNoOp() {
        var t = TerminalTabs<String>()
        t.goto(.next)
        XCTAssertNil(t.activeID)
    }
}
