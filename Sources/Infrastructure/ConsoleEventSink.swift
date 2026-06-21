import Application
import Foundation

/// Prints run lifecycle events to stdout. A real sink would fan out to the menu-bar badge,
/// a notification center, or a log file — same port, different adapter.
public struct ConsoleEventSink: RunEventSink {
    public init() {}

    public func emit(_ event: RunEvent) async {
        switch event {
        case .dispatched(let runID):
            print("[bosun] dispatched \(runID)")
        case .rejected(let runID, let reason):
            print("[bosun] rejected \(runID): \(reason)")
        }
    }
}
