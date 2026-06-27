import Foundation

/// One CI check run on a pull request's head commit. `durationSeconds` is present only for a
/// completed run with both timestamps; the presentation layer formats it (e.g. "1m42s").
public struct GitHubCheck: Sendable, Equatable, Codable {
    public let name: String
    public let state: CheckState
    public let durationSeconds: Int?
    /// Link to the run's details page (CheckRun `detailsUrl` / StatusContext `targetUrl`); nil when
    /// the forge reports no URL, in which case the presentation layer keeps the row inert.
    public let url: String?

    public init(name: String, state: CheckState, durationSeconds: Int? = nil, url: String? = nil) {
        self.name = name
        self.state = state
        self.durationSeconds = durationSeconds
        self.url = url
    }
}
