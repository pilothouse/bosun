import Foundation

/// The outcome of a CI check run, collapsed from GitHub's two-field protocol (`status` while
/// running, then `conclusion` once `completed`) into one value the UI can render directly.
/// Pure mapping rule — an unrecognized conclusion degrades to `.neutral` rather than throwing.
public enum CheckState: String, Sendable, Equatable, Codable {
    case queued
    case inProgress
    case success
    case failure
    case neutral
    case cancelled
    case skipped
    case timedOut
    case actionRequired

    /// Map GitHub's `(status, conclusion)` pair to a single state. Anything still running reads
    /// as `.queued`/`.inProgress`; a completed run reads from its conclusion.
    public static func from(status: String, conclusion: String?) -> CheckState {
        switch status {
        case "in_progress":
            return .inProgress
        case "completed":
            switch conclusion {
            case "success":          return .success
            case "failure",
                 "startup_failure":  return .failure
            case "cancelled":        return .cancelled
            case "skipped", "stale": return .skipped
            case "timed_out":        return .timedOut
            case "action_required":  return .actionRequired
            default:                 return .neutral   // "neutral", nil, or anything new
            }
        default:
            return .queued   // queued / waiting / requested / pending
        }
    }
}
