import Application
import Foundation

/// Production `Sleeper`: wraps `Task.sleep`, which throws `CancellationError` when the polling
/// Task is cancelled — that's how closing the sign-in sheet stops the loop mid-wait. A value
/// type with no state, so it's trivially `Sendable`.
public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}
