import Foundation

/// Pure rule for restoring the selected repo on launch. The persisted choice lives in
/// `Preferences.selectedRepoKey` (`owner/name`); the set of *available* repos comes from GitHub.
/// Keeping the branching here — not in the data controller — means the launch path and any future
/// caller share one definition of "is this saved selection still reachable", mirroring
/// `OrgFollowing`.
public enum RepoSelection {
    public enum Outcome: Equatable {
        /// The persisted repo is still available — select it.
        case restore(String)
        /// Nothing saved, or the saved repo is gone (access lost / deleted) — fall back to the
        /// existing first-repo auto-selection.
        case autoSelect
    }

    /// Honor `persisted` only when it's still among `available`; otherwise auto-select. The match
    /// is exact, so a stale key never resolves to a different repo that merely shares a prefix.
    public static func reconcile(persisted: String?, available: [String]) -> Outcome {
        if let persisted, available.contains(persisted) { return .restore(persisted) }
        return .autoSelect
    }
}
