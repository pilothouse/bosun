import Application
import Domain
import Foundation

/// Dev/test adapter: keeps runs in memory. A `SQLiteRunStore` would live beside this file,
/// conform to the same `RunStore` port, and get swapped in `CompositionRoot` — the use case
/// never knows the difference. An actor gives us free `Sendable` correctness for the store.
public actor InMemoryRunStore: RunStore {
    private var runs: [UUID: AgentRun] = [:]

    public init() {}

    public func activeRunCount(forOrg org: String) -> Int {
        runs.values.filter { $0.repo.owner == org && $0.status == .running }.count
    }

    public func save(_ run: AgentRun) {
        runs[run.id] = run
    }
}
