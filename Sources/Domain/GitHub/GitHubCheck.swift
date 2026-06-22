import Foundation

/// One CI check run on a pull request's head commit. `durationSeconds` is present only for a
/// completed run with both timestamps; the presentation layer formats it (e.g. "1m42s").
public struct GitHubCheck: Sendable, Equatable {
    public let name: String
    public let state: CheckState
    public let durationSeconds: Int?

    public init(name: String, state: CheckState, durationSeconds: Int? = nil) {
        self.name = name
        self.state = state
        self.durationSeconds = durationSeconds
    }
}
