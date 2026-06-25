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

    /// The active panel selection is either an org or a repo, never both. The store holds the two
    /// fields (`selectedOrgId: String`, `selectedRepoKey: String?`); `selectingOrg`/`selectingRepo`
    /// compute the resulting pair so the org-row click and the repo-select path share one definition
    /// of "only one is active".
    public struct Selection: Equatable {
        /// "" when a repo (or nothing) is the active selection.
        public let orgId: String
        /// nil when an org (or nothing) is the active selection.
        public let repoKey: String?
        public init(orgId: String, repoKey: String?) {
            self.orgId = orgId
            self.repoKey = repoKey
        }
    }

    /// After picking org `id`: that org is active, no repo.
    public static func selectingOrg(_ id: String) -> Selection { Selection(orgId: id, repoKey: nil) }

    /// After picking repo `key` (`owner/name`): that repo is active, no org.
    public static func selectingRepo(_ key: String) -> Selection { Selection(orgId: "", repoKey: key) }
}
