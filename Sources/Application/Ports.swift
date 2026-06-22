import Domain
import Foundation

public protocol RunStore: Sendable {
    func activeRunCount(forOrg org: String) async throws -> Int
    func save(_ run: AgentRun) async throws
}

public protocol AgentRunner: Sendable {
    func start(_ run: AgentRun) async throws
}

public protocol RunEventSink: Sendable {
    func emit(_ event: RunEvent) async
}

public enum RunEvent: Sendable {
    case dispatched(runID: UUID)
    case rejected(runID: UUID, reason: String)
}

/// Persistence seam for saved connections. The use cases talk to this port; a concrete
/// adapter (a JSON file, later a database) lives in Infrastructure and is wired in
/// `CompositionRoot`. `save` upserts by id.
public protocol ConnectionStore: Sendable {
    func all() async throws -> [Connection]
    func save(_ connection: Connection) async throws
    func delete(id: UUID) async throws
}
