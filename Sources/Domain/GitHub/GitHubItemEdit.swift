import Foundation

/// The fields of an issue/PR a user can change from the detail pane: `title`, `body`, `labels` and
/// `assignees`. Each is optional — nil means "leave this field as it is" — so one value can carry a
/// title-only save, a labels-only toggle, or any combination, mapping straight onto GitHub's partial
/// `PATCH .../issues/{number}` (the array fields *replace* the whole set). Bundled into one value so
/// the `GitHubAPI` port keeps its owner/repo/number/+payload shape rather than a long parameter list,
/// mirroring `PRMergeRequest`. The "don't save an empty title" rule lives in `EditItemUseCase`, not here.
public struct GitHubItemEdit: Sendable, Equatable {
    /// The new title, or nil to leave it unchanged.
    public var title: String?
    /// The new body, or nil to leave it unchanged. An empty string is a valid edit (clearing the body).
    public var body: String?
    /// The full replacement set of label names, or nil to leave labels unchanged.
    public var labels: [String]?
    /// The full replacement set of assignee logins, or nil to leave assignees unchanged.
    public var assignees: [String]?

    public init(title: String? = nil, body: String? = nil,
                labels: [String]? = nil, assignees: [String]? = nil) {
        self.title = title
        self.body = body
        self.labels = labels
        self.assignees = assignees
    }

    /// True when nothing would change — every field is nil. The use case rejects this so a stray save
    /// never issues a no-op write.
    public var isEmpty: Bool {
        title == nil && body == nil && labels == nil && assignees == nil
    }
}
