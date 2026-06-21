import Domain

public struct DispatchAgentUseCase: Sendable {
    private let store: RunStore
    private let runner: AgentRunner
    private let events: RunEventSink
    // 3 collaborators — at the limit. A 4th means this use case is doing two jobs.

    public init(store: RunStore, runner: AgentRunner, events: RunEventSink) {
        self.store = store
        self.runner = runner
        self.events = events
    }

    public func callAsFunction(
        run: AgentRun,
        maxConcurrentPerOrg: Int,
        repoIsPaused: Bool
    ) async throws {
        let active = try await store.activeRunCount(forOrg: run.repo.owner)
        guard DispatchPolicy.canDispatch(
            run: run,
            activeRunsInOrg: active,
            maxConcurrentPerOrg: maxConcurrentPerOrg,
            repoIsPaused: repoIsPaused
        ) else {
            await events.emit(.rejected(runID: run.id, reason: "org at concurrency limit or repo paused"))
            return
        }
        try await runner.start(run)
        try await store.save(run)
        await events.emit(.dispatched(runID: run.id))
    }
}
