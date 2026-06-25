import XCTest
@testable import Domain

/// Contract tests for `OrgItemScope.includesRepo` — the rule that decides which of an org's repos to
/// fetch when aggregating the org-wide issue/PR view. It promises: under the default open-only
/// filter, skip a repo with no open work (nothing to show); once the filter widens to closed/merged,
/// fetch every repo because the open count says nothing about history. Don't edit a contract test to
/// make an implementation pass — if the contract is wrong, flag it.
final class OrgItemScopeTests: XCTestCase {

    func testOpenOnlySkipsReposWithNoOpenWork() {
        XCTAssertFalse(OrgItemScope.includesRepo(open: 0, openOnly: true))
    }

    func testOpenOnlyKeepsReposWithOpenWork() {
        XCTAssertTrue(OrgItemScope.includesRepo(open: 5, openOnly: true))
    }

    func testBroaderFilterKeepsEvenEmptyRepos() {
        // Closed/merged are in scope — the open count can't rule a repo out, so fetch it anyway.
        XCTAssertTrue(OrgItemScope.includesRepo(open: 0, openOnly: false))
    }

    func testBroaderFilterKeepsReposWithOpenWork() {
        XCTAssertTrue(OrgItemScope.includesRepo(open: 9, openOnly: false))
    }
}
