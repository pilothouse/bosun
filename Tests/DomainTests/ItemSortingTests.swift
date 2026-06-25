import XCTest
@testable import Domain

/// Contract tests for the pure issue/PR sorting rule. They describe what `ItemSorting` promises
/// outward — the order items take for a given field and direction — not how it works inside. The
/// rule operates on `(date, number, title)` projections so Domain needn't know the App's
/// presentation `Item` type; here a tiny local fixture supplies those. Don't edit a contract test to
/// make an implementation pass; if the contract is wrong, flag it. Mirrors `RepoOrderingTests`.
final class ItemSortingTests: XCTestCase {

    private struct I { let date: Date; let number: Int; let title: String }

    /// A fixed reference date plus an offset in days, so the fixtures read as relative ages.
    private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400) }

    private func sort(_ items: [I], by field: ItemSortField, ascending: Bool) -> [Int] {
        ItemSorting.sort(items, by: field, ascending: ascending,
                         date: \.date, number: \.number, title: \.title).map(\.number)
    }

    // MARK: date

    func testDateAscendingIsOldestFirst() {
        let items = [I(date: day(2), number: 1, title: "b"),
                     I(date: day(0), number: 2, title: "a"),
                     I(date: day(1), number: 3, title: "c")]
        XCTAssertEqual(sort(items, by: .date, ascending: true), [2, 3, 1])
    }

    func testDateDescendingIsNewestFirst() {
        let items = [I(date: day(2), number: 1, title: "b"),
                     I(date: day(0), number: 2, title: "a"),
                     I(date: day(1), number: 3, title: "c")]
        XCTAssertEqual(sort(items, by: .date, ascending: false), [1, 3, 2])
    }

    func testEqualDatesBreakTieByNumberAscending() {
        // Same instant → fall back to number so the order is deterministic.
        let items = [I(date: day(0), number: 9, title: "z"),
                     I(date: day(0), number: 3, title: "y"),
                     I(date: day(0), number: 7, title: "x")]
        XCTAssertEqual(sort(items, by: .date, ascending: true), [3, 7, 9])
    }

    // MARK: number

    func testNumberAscending() {
        let items = [I(date: day(0), number: 30, title: "a"),
                     I(date: day(0), number: 4, title: "b"),
                     I(date: day(0), number: 12, title: "c")]
        XCTAssertEqual(sort(items, by: .number, ascending: true), [4, 12, 30])
    }

    func testNumberDescending() {
        let items = [I(date: day(0), number: 30, title: "a"),
                     I(date: day(0), number: 4, title: "b"),
                     I(date: day(0), number: 12, title: "c")]
        XCTAssertEqual(sort(items, by: .number, ascending: false), [30, 12, 4])
    }

    // MARK: title

    func testTitleSortsCaseInsensitivelyAscending() {
        let items = [I(date: day(0), number: 1, title: "beta"),
                     I(date: day(0), number: 2, title: "Alpha"),
                     I(date: day(0), number: 3, title: "gamma")]
        XCTAssertEqual(sort(items, by: .title, ascending: true), [2, 1, 3],
                       "title order ignores case")
    }

    func testTitleDescending() {
        let items = [I(date: day(0), number: 1, title: "beta"),
                     I(date: day(0), number: 2, title: "Alpha"),
                     I(date: day(0), number: 3, title: "gamma")]
        XCTAssertEqual(sort(items, by: .title, ascending: false), [3, 1, 2])
    }

    func testEqualTitlesBreakTieByNumberAscending() {
        let items = [I(date: day(0), number: 9, title: "dup"),
                     I(date: day(0), number: 3, title: "Dup"),
                     I(date: day(0), number: 7, title: "DUP")]
        XCTAssertEqual(sort(items, by: .title, ascending: true), [3, 7, 9])
    }

    // MARK: edges

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(sort([], by: .date, ascending: true), [])
        XCTAssertEqual(sort([], by: .number, ascending: false), [])
        XCTAssertEqual(sort([], by: .title, ascending: true), [])
    }

    func testDefaultFieldIsDate() {
        XCTAssertEqual(ItemSortField.default, .date)
    }
}
