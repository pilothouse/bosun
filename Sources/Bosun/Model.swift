import AppKit
import Domain

// The default tint for a non-agent item's right-hand meta (theme-independent).
private let dim = Status.dim

enum ConnKind { case ssh, folder }
enum ItemKind { case issue, pr }

struct Repo { let id, name: String; let open: Int; var owner = ""; var stars = 0; var isPrivate = false }

/// `color` is the deterministic placeholder tint; `avatarURL` (when present) is the real org icon
/// the `AvatarView` async-loads over it.
struct Org { let id, name: String; let color: NSColor; let avatarURL: URL?; let repos: [Repo] }

struct Connection {
    let id, name: String
    let kind: ConnKind
    let meta: String
    var isFavorite = false
    var glyph: String { kind == .ssh ? "⧉" : "▦" }
    var kindLabel: String { kind == .ssh ? "SSH" : "FOLDER" }
}

extension Connection {
    /// Presentation projection of a persisted `Domain.Connection`.
    init(domain c: Domain.Connection) {
        let kind: ConnKind
        let meta: String
        switch c.kind {
        case let .ssh(host, _, _): kind = .ssh; meta = host
        case let .localFolder(path): kind = .folder; meta = path
        }
        self.init(id: c.id.uuidString, name: c.name, kind: kind, meta: meta,
                  isFavorite: c.isFavorite)
    }

    /// Shown only in the brief window before the persisted list loads (or if it's empty).
    static let placeholder = Connection(id: "", name: "—", kind: .folder, meta: "")
}

/// A rendered band of the connection rail — the presentation projection of
/// `Domain.ConnectionSection`. Favorites is pinned, a `.folder` carries its id+name (for the
/// header's rename/delete/collapse and as a drag drop target), and `.ungrouped` is the catch-all.
/// Built by `Store.connectionSections`; the rail iterates these to lay out headers and rows (#82).
struct ConnSection {
    enum Kind: Equatable {
        case favorites
        case folder(id: String, name: String)
        case ungrouped
    }
    let kind: Kind
    let connections: [Connection]
}

struct TaskItem { let label: String; let done: Bool }
struct Check { let name, icon: String; let color: NSColor; let dur, statusText: String; var running = false; var url: String? }
/// One changed file in a PR's `FILES CHANGED` section. `glyph`/`color` encode the change type
/// (A/M/D/R/C); `add`/`del` are the per-file line counts. Built by `FileChange.init(domain:)`.
struct FileChange { let path, glyph: String; let color: NSColor; let add, del: Int }
struct Comment { let author, initials: String; let color: NSColor; let time, badge, body: String; let avatarURL: URL? }

/// The signed-in viewer, projected for the comment composer's avatar. `color`/`initials` are the
/// placeholder the `AvatarView` shows until `avatarURL` (the viewer's real avatar) loads.
struct CurrentUser { let initials: String; let color: NSColor; let avatarURL: URL? }

/// A person assigned to an item, projected for the detail pane's metadata section. Like `Comment`,
/// `color`/`initials` are the `AvatarView` placeholder shown until `avatarURL` loads.
struct Assignee { let login, initials: String; let color: NSColor; let avatarURL: URL? }

/// A PR reviewer, projected for the detail pane's REVIEWERS section (issue #70). `color`/`initials`
/// are the `AvatarView` placeholder like `Assignee`; `state` carries the review verdict, which the
/// view renders as a colored badge (and gates removal — only a `.pending` request is removable).
struct Reviewer { let login, initials: String; let color: NSColor; let avatarURL: URL?; let state: GitHubReviewState }

/// Whether a reviewer toggle requests a review or cancels a pending request (issue #70) — the two
/// `…/requested_reviewers` writes. The detail pane hands this to the data controller.
enum ReviewerAction { case request, remove }

/// A label a repository defines, offered in the edit pane's label picker (issue #71). `color` is the
/// label's display tint (nil → a neutral chip), pre-resolved from the hex `GitHubLabel` carries.
struct LabelChoice { let name: String; let color: NSColor? }

/// Presentation projection of a GitHub issue/PR. Built from `Domain.GitHubItem` by the mapper in
/// `GitHubPresentation.swift` (colors, glyphs, and relative-time strings live there); the views
/// render straight off these fields. `tasks`/`checks`/`comments` are populated by the detail fetch.
struct Item {
    let id, num: String
    /// The item title. `var` so an in-place edit (issue #71) updates the list row and detail without a
    /// re-fetch; everything else reads it.
    var title: String
    /// The issue/PR number, the raw value behind the `num` display string ("#123"). Kept so the
    /// list can sort by number. See `ItemSorting`.
    let number: Int
    let kind: ItemKind
    /// The Domain lifecycle state, carried so the panel's status filter can include/exclude this
    /// item without re-deriving it from the status label.
    var state: GitHubItemState = .open
    // The status chip (glyph/label/colors). `var` so a local merge/close can refresh the badge in
    // place via `applyResolved(state:)` — a merged/closed row that stays visible under a
    // closed-inclusive filter shows the terminal chip, not a stale "open" dot.
    var glyph: String
    var gcolor: NSColor
    var statusLabel: String
    var statusColor: NSColor
    var dotColor: NSColor
    let age, author: String
    /// The item's label names, carried raw (not just the first, as `metaLeft` shows) so the list's
    /// free-text search can match any label via the `GitHubItemSearch` rule.
    var labels: [String] = []
    /// Label name → display color, for labels that ship a color. Carried on both list and detail
    /// items, so the detail pane shows colored pills the instant a row is selected (no recolor when
    /// the detail lands). The pane tints each pill via this map, falling back to a neutral chip.
    var labelColors: [String: NSColor] = [:]
    /// The people assigned to this item, shown in the detail pane's metadata section. Carried on
    /// both list and detail items so the section is complete on the lead row (no body jump when the
    /// detail lands). Empty when none.
    var assignees: [Assignee] = []
    /// The PR's reviewers and their review states, shown in the detail pane's REVIEWERS section
    /// (issue #70). PR-only and detail-hydrated (unlike `assignees`, the list fetch doesn't carry
    /// it), so it's empty until the detail lands. Updated in place by a request/remove.
    var reviewers: [Reviewer] = []
    /// The item's milestone title, or nil when it has none. Carried on the list row too, like
    /// `assignees`, so the metadata section doesn't grow when the detail lands.
    var milestone: String? = nil
    /// When the item was created, the raw value behind the `age` display string. Kept so the list
    /// can sort by date. See `ItemSorting`.
    let createdAt: Date
    let authorColor: NSColor
    let authorInitials: String
    let authorAvatarURL: URL?
    var isAgent = false
    /// `metaLeft` is the list row's left-hand meta (a PR's branch, else the first label); `var` so an
    /// edit can recompute it in place when labels change (issue #71). `metaRight` is the agent tag.
    var metaLeft: String
    let metaRight: String
    var agentColor: NSColor = dim
    /// The item body (markdown). `var` for the same in-place-edit reason as `title` (issue #71).
    var body: String
    var tasks: [TaskItem] = []
    var checks: [Check] = []
    var files: [FileChange] = []
    var comments: [Comment] = []
    var branch: String? = nil
    var add: Int? = nil
    var del: Int? = nil
    var blocked: String? = nil
    var parent: String? = nil
    var epic = false
    var repo = ""
    /// The item's GitHub web URL (issue or PR), used by the detail view's copy-link affordance.
    var url = ""
    /// PR mergeability, carried so the detail pane's merge control can enable/disable itself via
    /// `PRMergePolicy`. `mergeable`: true (MERGEABLE), false (CONFLICTING), nil (UNKNOWN / not yet
    /// hydrated). `mergeStateStatus`: GitHub's raw status (CLEAN/BLOCKED/DRAFT/…). `baseRef`: the
    /// target branch a merge lands on. All nil for issues and lead (un-hydrated) rows.
    var mergeable: Bool? = nil
    var mergeStateStatus: String? = nil
    var baseRef: String? = nil
    /// Whether the PR's head branch lives in a fork (cross-repository). Detail-hydrated; nil for
    /// issues / un-hydrated rows. Gates the "Delete branch" option on close via `PRClosePolicy` — a
    /// fork's branch can't be deleted from the base repo.
    var isCrossRepository: Bool? = nil
}

extension Item {
    /// `repo` ("owner/name") split into its parts, so the data controller can route this item's
    /// detail/comment fetch to its own repo — the aggregate org view mixes items from many repos, so
    /// the scope can't be assumed. nil if `repo` is empty/malformed.
    var ownerRepo: (owner: String, name: String)? {
        guard let slash = repo.firstIndex(of: "/") else { return nil }
        return (String(repo[..<slash]), String(repo[repo.index(after: slash)...]))
    }
}
