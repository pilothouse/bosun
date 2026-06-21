import XCTest
import Domain
@testable import Application

/// Contract tests for the dispatch use case, driven entirely through its ports. The seam
/// (RunStore / AgentRunner / RunEventSink) is exactly what lets us run against fakes here
/// instead of a live SSH connection.
final class DispatchAgentUseCaseTests: XCTestCase {

    // MARK: Fakes (in-test implementations of Application's ports)

    private actor FakeRunStore: RunStore {
        private let active: Int
        private(set) var saved: [AgentRun] = []
        init(active: Int) { self.active = active }
        func activeRunCount(forOrg org: String) -> Int { active }
        func save(_ run: AgentRun) { saved.append(run) }
    }

    private actor FakeRunner: AgentRunner {
        private(set) var started: [AgentRun] = []
        func start(_ run: AgentRun) { started.append(run) }
    }

    private actor RecordingSink: RunEventSink {
        private(set) var events: [RunEvent] = []
        func emit(_ event: RunEvent) { events.append(event) }
    }

    private func makeRun() -> AgentRun {
        AgentRun(
            id: UUID(),
            repo: RepoRef(forge: .github, owner: "acme-corp", name: "api-gateway"),
            prompt: "fix the flaky test"
        )
    }

    // MARK: Tests

    func testDispatchesWhenUnderBudget() async throws {
        let store = FakeRunStore(active: 1)
        let runner = FakeRunner()
        let sink = RecordingSink()
        let dispatch = DispatchAgentUseCase(store: store, runner: runner, events: sink)
        let run = makeRun()

        try await dispatch(run: run, maxConcurrentPerOrg: 3, repoIsPaused: false)

        let started = await runner.started
        let saved = await store.saved
        let events = await sink.events
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(saved.count, 1)
        guard case .dispatched = events.first else {
            return XCTFail("expected a .dispatched event, got \(events)")
        }
    }

    func testRejectsAtConcurrencyLimit() async throws {
        let store = FakeRunStore(active: 3)
        let runner = FakeRunner()
        let sink = RecordingSink()
        let dispatch = DispatchAgentUseCase(store: store, runner: runner, events: sink)

        try await dispatch(run: makeRun(), maxConcurrentPerOrg: 3, repoIsPaused: false)

        let started = await runner.started
        let events = await sink.events
        XCTAssertTrue(started.isEmpty, "runner must not start a rejected run")
        guard case .rejected = events.first else {
            return XCTFail("expected a .rejected event, got \(events)")
        }
    }
}
