import Application
import Domain
import Foundation

/// The ONLY layer that knows about SSH and remote processes. Swap it for a fake in tests.
public final class SSHAgentRunner: AgentRunner {
    public init() {}

    public func start(_ run: AgentRun) async throws {
        // open SSH to the org's LXC, spawn `claude -p ...`, stream OSC notifications.
        // Concrete transport detail lives here and nowhere else.
        _ = run
    }
}
