/// The three reasons GitHub accepts when closing an issue via `state_reason`.
/// Sent as `state_reason` in the REST PATCH body; the raw values match GitHub's API strings.
public enum IssueCloseReason: String, Sendable, CaseIterable {
    case completed
    case notPlanned = "not_planned"
    case duplicate

    /// The label the primary close button shows for this reason (mirrors `PRMergeMethod.buttonTitle`).
    /// `.completed` reads "Close issue" (GitHub's default); the others spell out the reason.
    public var buttonTitle: String {
        switch self {
        case .completed:  return "Close issue"
        case .notPlanned: return "Close as not planned"
        case .duplicate:  return "Close as duplicate"
        }
    }

    /// The label in the reason dropdown, where every entry spells out the reason (so `.completed`
    /// reads "Close as completed" even though its button says "Close issue").
    public var menuTitle: String {
        switch self {
        case .completed:  return "Close as completed"
        case .notPlanned: return "Close as not planned"
        case .duplicate:  return "Close as duplicate"
        }
    }
}
