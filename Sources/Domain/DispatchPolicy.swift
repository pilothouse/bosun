import Foundation

public enum DispatchPolicy {
    /// A run may dispatch only if its org is under concurrency budget and the repo
    /// isn't paused. Pure — one unit test, callable from menu bar, CLI, or sweep alike.
    public static func canDispatch(
        run: AgentRun,
        activeRunsInOrg: Int,
        maxConcurrentPerOrg: Int,
        repoIsPaused: Bool
    ) -> Bool {
        guard run.status == .queued, !repoIsPaused else { return false }
        return activeRunsInOrg < maxConcurrentPerOrg
    }
}
