import XCTest
@testable import Domain

/// Contract tests for `RepoSelection.reconcile` — the rule that decides, on launch, whether to
/// honor the persisted repo selection or fall back to the first-repo auto-selection. It promises:
/// honor a persisted key only while it's still among the available repos (the user still has
/// access), otherwise auto-select. Don't edit a contract test to make an implementation pass — if
/// the contract is wrong, flag it.
final class RepoSelectionTests: XCTestCase {

    func testHonorsPersistedKeyWhenStillAvailable() {
        let outcome = RepoSelection.reconcile(
            persisted: "acme/widgets",
            available: ["acme/gadgets", "acme/widgets", "maya/app"])
        XCTAssertEqual(outcome, .restore("acme/widgets"))
    }

    func testFallsBackWhenPersistedKeyIsNoLongerAvailable() {
        // Access lost, or the repo was deleted/renamed — it's gone from the available set.
        let outcome = RepoSelection.reconcile(
            persisted: "acme/widgets",
            available: ["acme/gadgets", "maya/app"])
        XCTAssertEqual(outcome, .autoSelect)
    }

    func testFallsBackWhenNothingPersisted() {
        let outcome = RepoSelection.reconcile(persisted: nil, available: ["acme/gadgets"])
        XCTAssertEqual(outcome, .autoSelect)
    }

    func testFallsBackWhenNoReposAreAvailable() {
        let outcome = RepoSelection.reconcile(persisted: "acme/widgets", available: [])
        XCTAssertEqual(outcome, .autoSelect)
    }

    func testMatchIsExactNotAPrefix() {
        // "acme/widgets" must not be considered satisfied by a different repo that shares a prefix.
        let outcome = RepoSelection.reconcile(
            persisted: "acme/widgets",
            available: ["acme/widgets-2", "acme/widgetsx"])
        XCTAssertEqual(outcome, .autoSelect)
    }
}
