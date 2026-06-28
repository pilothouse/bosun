import Foundation

/// A label a repository defines — its `name` and optional `color` (a hex string like `"d73a4a"`, no
/// leading `#`). The candidate offered by the label picker when editing an item: the issue/PR model
/// keeps applied labels as `[String]` plus a parallel `labelColors`, which has no name→color pairs to
/// list in a picker, so the "what labels can I add?" fetch returns these instead. Pure value type —
/// the presentation layer turns `color` into an `NSColor`.
public struct GitHubLabel: Sendable, Equatable, Codable {
    public let name: String
    public let color: String?

    public init(name: String, color: String? = nil) {
        self.name = name
        self.color = color
    }
}
