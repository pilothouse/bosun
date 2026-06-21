import XCTest
@testable import Domain

/// Contract tests for the pure dispatch rule. They describe what `DispatchPolicy` promises
/// outward, not how it works inside. Don't edit a contract test to make an implementation
/// pass — if the contract is wrong, flag it.
final class DispatchPolicyTests: XCTestCase {
    private func makeRun(status: RunStatus = .queued) -> AgentRun {
        AgentRun(
            id: UUID(),
            repo: RepoRef(forge: .github, owner: "acme-corp", name: "api-gateway"),
            prompt: "fix the flaky test",
            status: status
        )
    }

    func testDispatchesWhenUnderBudgetAndQueued() {
        XCTAssertTrue(DispatchPolicy.canDispatch(
            run: makeRun(),
            activeRunsInOrg: 2,
            maxConcurrentPerOrg: 3,
            repoIsPaused: false
        ))
    }

    func testRejectsAtConcurrencyLimit() {
        XCTAssertFalse(DispatchPolicy.canDispatch(
            run: makeRun(),
            activeRunsInOrg: 3,
            maxConcurrentPerOrg: 3,
            repoIsPaused: false
        ))
    }

    func testRejectsWhenRepoPaused() {
        XCTAssertFalse(DispatchPolicy.canDispatch(
            run: makeRun(),
            activeRunsInOrg: 0,
            maxConcurrentPerOrg: 3,
            repoIsPaused: true
        ))
    }

    func testRejectsWhenNotQueued() {
        XCTAssertFalse(DispatchPolicy.canDispatch(
            run: makeRun(status: .running),
            activeRunsInOrg: 0,
            maxConcurrentPerOrg: 3,
            repoIsPaused: false
        ))
    }
}
