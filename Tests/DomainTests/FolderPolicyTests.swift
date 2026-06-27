import XCTest
@testable import Domain

/// Contract tests for the pure folder-name rule. They describe what `FolderPolicy` promises
/// outward — a folder must have a non-blank name — not how it checks it. Mirrors
/// `ConnectionPolicyTests`. Don't edit a contract test to make an implementation pass.
final class FolderPolicyTests: XCTestCase {

    func testAcceptsANonEmptyName() {
        XCTAssertEqual(FolderPolicy.validate(name: "Project Acme"), [])
    }

    func testRejectsAnEmptyName() {
        XCTAssertEqual(FolderPolicy.validate(name: ""), [.emptyName])
    }

    func testRejectsAWhitespaceOnlyName() {
        XCTAssertEqual(FolderPolicy.validate(name: "   \n\t"), [.emptyName])
    }

    func testAcceptsANameWithSurroundingWhitespace() {
        // The name is non-blank once trimmed; trimming itself happens at save time.
        XCTAssertEqual(FolderPolicy.validate(name: "  staging  "), [])
    }
}
