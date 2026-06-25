import XCTest
@testable import Domain

/// Contract tests for the pure detail-reselection rule. They describe what `DetailReselectionPolicy`
/// promises outward, not how it works inside. Don't edit a contract test to make an implementation
/// pass — if the contract is wrong, flag it.
final class DetailReselectionPolicyTests: XCTestCase {
    func testSkipsReclickOfLoadedItem() {
        // The open item's detail is already loaded; clicking it again must not refetch.
        XCTAssertFalse(DetailReselectionPolicy.shouldFetchDetail(loadedDetailId: "5", target: "5"))
    }

    func testFetchesDifferentItem() {
        XCTAssertTrue(DetailReselectionPolicy.shouldFetchDetail(loadedDetailId: "5", target: "9"))
    }

    func testFetchesWhenNoDetailLoaded() {
        // First open, or a retry after a failed/aborted fetch left no loaded detail.
        XCTAssertTrue(DetailReselectionPolicy.shouldFetchDetail(loadedDetailId: nil, target: "9"))
    }

    func testFetchesWhenLoadedDetailIsStalePreviousItem() {
        // A new selection arrives while the previous item's detail is still the loaded one.
        XCTAssertTrue(DetailReselectionPolicy.shouldFetchDetail(loadedDetailId: "5", target: "12"))
    }
}
