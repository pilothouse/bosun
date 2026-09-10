import XCTest
@testable import Domain

/// Contract tests for the pure copy-naming rule. They describe what `ConnectionNaming` promises
/// outward — that duplicating a connection yields a name nobody else is using, derived from the
/// original rather than stacked on top of a previous copy — not how it works inside. The rule takes
/// plain strings so Domain needn't know where the existing names came from. Don't edit a contract
/// test to make an implementation pass; if the contract is wrong, flag it.
final class ConnectionNamingTests: XCTestCase {

    func testFirstCopyAppendsTheSuffix() {
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box", existing: ["build-box"]),
                       "build-box (copy)",
                       "the first duplicate is the plain (copy) form")
    }

    func testNoExistingNamesStillProducesTheFirstCopy() {
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box", existing: []),
                       "build-box (copy)")
    }

    func testATakenCopyNameIsNumbered() {
        let existing = ["build-box", "build-box (copy)"]
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box", existing: existing),
                       "build-box (copy 2)",
                       "duplicating twice must not collide with the first copy")
    }

    func testNumberingContinuesPastTheSecondCopy() {
        let existing = ["build-box", "build-box (copy)", "build-box (copy 2)"]
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box", existing: existing),
                       "build-box (copy 3)")
    }

    func testTheFirstFreeNumberIsUsed() {
        // A gap left by a deleted copy is reused rather than skipped.
        let existing = ["build-box", "build-box (copy)", "build-box (copy 3)"]
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box", existing: existing),
                       "build-box (copy 2)")
    }

    func testDuplicatingACopyDoesNotStackSuffixes() {
        let existing = ["build-box", "build-box (copy)"]
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box (copy)", existing: existing),
                       "build-box (copy 2)",
                       "a copy of a copy is numbered from the base, not ‘(copy) (copy)’")
    }

    func testDuplicatingANumberedCopyAlsoNumbersFromTheBase() {
        let existing = ["build-box", "build-box (copy)", "build-box (copy 2)"]
        XCTAssertEqual(ConnectionNaming.copyName(of: "build-box (copy 2)", existing: existing),
                       "build-box (copy 3)")
    }

    func testASuffixInTheMiddleOfANameIsNotStripped() {
        // Only a *trailing* suffix marks a copy; anything else is part of the user's chosen name.
        XCTAssertEqual(ConnectionNaming.copyName(of: "a (copy) b", existing: []),
                       "a (copy) b (copy)")
    }

    func testANameThatIsOnlyTheSuffixIsNotStrippedToBlank() {
        XCTAssertEqual(ConnectionNaming.copyName(of: "(copy)", existing: ["(copy)"]),
                       "(copy) (copy)",
                       "stripping must never leave a blank base — a connection needs a name")
    }

    func testANonNumericSuffixIsNotTreatedAsACopyMarker() {
        XCTAssertEqual(ConnectionNaming.copyName(of: "box (copy v2)", existing: []),
                       "box (copy v2) (copy)")
    }
}
