import AppKit
import Domain

/// Projections from the live Domain GitHub types onto the presentation structs the views render.
/// This is the App layer's job: Domain stays free of AppKit (it deliberately leaves "colors and
/// glyphs to the presentation layer"), so the status→color/glyph mapping and relative-time
/// formatting land here, mirroring the existing `Connection.init(domain:)` projection. The pure,
/// reusable sub-rules (`GitHubRelativeAge`, `GitHubActor.initials/isBot`) live in Domain and are
/// unit-tested; everything here is deterministic presentation glue verified by running the app.

/// The agent accent (same blue the device-flow/account chrome uses) for bot-authored work.
private let agentAccent = NSColor.hex(0x7c8cff)

extension Org {
    init(domain o: GitHubOrg) {
        self.init(id: o.id,
                  name: o.name ?? o.login,
                  color: Org.color(forLogin: o.login),
                  avatarURL: o.avatarURL,
                  repos: o.repositories.map(Repo.init(domain:)))
    }

    /// A synthetic panel group for the viewer's own repositories, shown above the orgs so an account
    /// with no org membership still sees live data. Keyed off the viewer's login (every personal
    /// repo's `owner` is the viewer, so no extra identity fetch is needed). Returns nil when there
    /// are no personal repos — there's no empty group to render.
    init?(personalRepos repos: [GitHubRepo], viewer: GitHubUser?) {
        guard let login = repos.first?.owner else { return nil }
        self.init(id: Org.personalID,
                  name: "@\(login)",
                  color: Org.color(forLogin: login),
                  // No org node here, but the synthetic group *is* the viewer — so use the viewer's
                  // real avatar. Nil (not yet fetched / none) falls back to the colored monogram.
                  avatarURL: viewer?.avatarURL,
                  repos: repos.map(Repo.init(domain:)))
    }

    /// Stable sentinel id for the synthetic personal group. Prefixed so it can't collide with a
    /// GraphQL org node id (and stays consistent across launches for the follow/order persistence).
    static let personalID = "viewer:personal"

    /// Stable sentinel id for the synthetic "All organizations" aggregate row. Not a real entry in
    /// `store.orgs` — resolved to the union of every visible org's repos wherever an org is looked
    /// up by id (see `Store.allOrgRepos`). Prefixed like `personalID` so it can't collide with a
    /// GraphQL org node id and stays consistent across launches for the scope-restore persistence.
    static let allOrgsID = "viewer:allOrgs"

    /// A deterministic accent per org (keyed off the login's scalars, not `hashValue`, which is
    /// per-process randomized) so the sidebar squares stay consistent within and across launches.
    private static func color(forLogin login: String) -> NSColor {
        let palette: [UInt32] = [0x7c8cff, 0xe0823d, 0xd2a8ff, 0x3fb950, 0x58a6ff, 0xdb6d28]
        let sum = login.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return .hex(palette[sum % palette.count])
    }
}

extension Repo {
    init(domain r: GitHubRepo) {
        // The sidebar shows one "open" badge; the API reports issues and PRs separately.
        self.init(id: r.id, name: r.name, open: r.openIssues + r.openPullRequests, owner: r.owner,
                  stars: r.stargazerCount, isPrivate: r.isPrivate)
    }
}

extension Item {
    /// One init for both list (lead) and detail items: a lead item simply carries empty
    /// `comments`/`checks`/`tasks`, which map to empty arrays, so the detail fetch just upgrades
    /// the same shape in place. PR-only `branch`/`additions`/`deletions` are nil for issues.
    init(domain it: GitHubItem) {
        let isAgent = it.author.isBot
        let status = Item.status(for: it)
        let isEpic = it.labels.contains { $0.caseInsensitiveCompare("epic") == .orderedSame }
        self.init(
            // Globally unique across repos (`owner/name#number`) so the org-aggregate view can list
            // items from many repos without two repos' identically-numbered items colliding on
            // selection/collapse. The raw number stays in `number`; the repo in `repo`.
            id: "\(it.repositoryNameWithOwner)#\(it.number)",
            num: "#\(it.number)",
            title: it.title,
            number: it.number,
            kind: it.kind == .pullRequest ? .pr : .issue,
            state: it.state,
            glyph: status.glyph,
            gcolor: status.color,
            statusLabel: status.label,
            statusColor: status.color,
            dotColor: status.color,
            age: GitHubRelativeAge.compact(from: it.createdAt, now: Date()),
            author: it.author.login,
            labels: it.labels,
            labelColors: (it.labelColors ?? [:]).compactMapValues(NSColor.hex(string:)),
            assignees: (it.assignees ?? []).map(Assignee.init(domain:)),
            reviewers: (it.reviewers ?? []).map(Reviewer.init(domain:)),
            milestone: it.milestone,
            createdAt: it.createdAt,
            authorColor: isAgent ? agentAccent : Status.purple,
            authorInitials: it.author.initials,
            authorAvatarURL: it.author.avatarURL,
            isAgent: isAgent,
            metaLeft: Item.metaLeft(for: it),
            metaRight: isAgent ? "◆ agent" : "",
            agentColor: isAgent ? Status.purple : Status.dim,
            body: it.body,
            tasks: it.tasks.map(TaskItem.init(domain:)),
            checks: it.checks.map(Check.init(domain:)),
            files: (it.files ?? []).map(FileChange.init(domain:)),
            comments: it.comments.map(Comment.init(domain:)),
            branch: it.branch,
            add: it.additions,
            del: it.deletions,
            // Blocked-by is enriched lazily by the controller (one REST call per issue), only when
            // the "By blocked-by" grouping is active — so it starts nil and is filled in later.
            blocked: nil,
            // The sub-issue parent rides the list fetch; key it by number to match this `id`.
            parent: it.parentNumber.map(String.init),
            epic: isEpic,
            repo: it.repositoryNameWithOwner,
            // Web URL for the copy-link affordance; the kind picks `pull` vs `issues`.
            url: "https://github.com/\(it.repositoryNameWithOwner)/" +
                 "\(it.kind == .pullRequest ? "pull" : "issues")/\(it.number)",
            // PR mergeability for the detail pane's merge control (nil for issues / lead rows).
            mergeable: it.mergeable,
            mergeStateStatus: it.mergeStateStatus,
            baseRef: it.baseRefName,
            isCrossRepository: it.isCrossRepository
        )
    }

    /// The status chip the cards/detail show. Open PRs reflect their checks once hydrated (the
    /// list fetch carries none, so it reads as plain "open"); issues surface an "epic" label.
    private static func status(for it: GitHubItem) -> (label: String, color: NSColor, glyph: String) {
        // Terminal states (merged/closed) badge the same wherever they're set — share one source
        // with `applyResolved(state:)` so the initial projection and an in-place merge/close agree.
        if let terminal = terminalBadge(isPR: it.kind == .pullRequest, state: it.state) { return terminal }
        switch it.kind {
        case .pullRequest:
            if it.isDraft { return ("draft", Status.dim, "○") }
            if let fromChecks = checksStatus(it.checks) { return fromChecks }
            return ("open", Status.green, "●")
        case .issue:
            if it.labels.contains(where: { $0.caseInsensitiveCompare("epic") == .orderedSame }) {
                return ("epic", Status.purple, "◆")
            }
            return ("open", Status.green, "○")
        }
    }

    /// The status chip for a *terminal* lifecycle state (a merged/closed PR, or a closed issue), or
    /// nil while the item is still open. Terminal badges don't depend on checks/draft/epic, so this
    /// small mapping is the single source both `status(for:)` and `Item.applyResolved(state:)` read
    /// — a local merge/close can refresh the row's badge without re-deriving it from a fetch.
    static func terminalBadge(isPR: Bool, state: GitHubItemState)
        -> (label: String, color: NSColor, glyph: String)? {
        switch state {
        case .merged: return isPR ? ("merged", Status.purple, "✓") : nil   // issues can't merge
        case .closed: return isPR ? ("closed", Status.red, "✕") : ("closed", Status.purple, "✓")
        case .open: return nil
        }
    }

    private static func checksStatus(_ checks: [GitHubCheck]) -> (label: String, color: NSColor, glyph: String)? {
        guard !checks.isEmpty else { return nil }
        if checks.contains(where: { $0.state == .failure || $0.state == .timedOut }) {
            return ("checks failing", Status.red, "✕")
        }
        if checks.contains(where: { $0.state == .inProgress || $0.state == .queued }) {
            return ("checks running", Status.yellow, "●")
        }
        return ("checks passed", Status.green, "✓")
    }

    private static func metaLeft(for it: GitHubItem) -> String {
        if let branch = it.branch, !branch.isEmpty { return "⎇ \(branch)" }
        return it.labels.first ?? ""
    }

    /// Layer the user-editable fields of a freshly-saved `GitHubItem` (issue #71) onto this
    /// presentation item, leaving the detail-only collections (comments/checks/files) and PR fields
    /// untouched — so an edit refreshes the title/body/labels/assignees/milestone in place without a
    /// re-fetch. `metaLeft` is recomputed so a changed first label shows in the list row; the derived
    /// *status* chip (`statusLabel`/`glyph`, e.g. an issue gaining the `epic` label) is left as-is and
    /// reconciles on the next list/detail refresh — a deliberate, minor staleness for snappy edits.
    mutating func applyEdited(from it: GitHubItem) {
        title = it.title
        body = it.body
        state = it.state
        labels = it.labels
        labelColors = (it.labelColors ?? [:]).compactMapValues(NSColor.hex(string:))
        assignees = (it.assignees ?? []).map(Assignee.init(domain:))
        milestone = it.milestone
        metaLeft = Item.metaLeft(for: it)
    }

    /// Reflect a terminal state applied locally (a merged/closed PR, or a closed issue) on this list
    /// row: update the lifecycle `state` the status filter reads, so a merged/closed item drops out
    /// of an open-only list at once, and refresh the status badge so a row still visible under a
    /// closed-inclusive filter shows "merged"/"closed" instead of a stale "open" chip. The
    /// detail-only collections (comments/checks/…) are untouched — this is the list-row counterpart
    /// to `refreshDetail`. A non-terminal state (or an issue marked `merged`, which can't happen)
    /// updates `state` only, leaving the derived badge to the next refresh, mirroring `applyEdited`.
    mutating func applyResolved(state newState: GitHubItemState) {
        state = newState
        guard let badge = Item.terminalBadge(isPR: kind == .pr, state: newState) else { return }
        glyph = badge.glyph
        gcolor = badge.color
        statusLabel = badge.label
        statusColor = badge.color
        dotColor = badge.color
    }
}

extension Assignee {
    /// The metadata-section/edit-picker projection of an actor: the canonical `initials` rule plus the
    /// agent/human placeholder tint shown until the real `avatarURL` loads (bots take the agent accent).
    init(domain actor: GitHubActor) {
        self.init(login: actor.login, initials: actor.initials,
                  color: actor.isBot ? agentAccent : Status.purple, avatarURL: actor.avatarURL)
    }
}

extension Reviewer {
    /// The REVIEWERS-section projection of a `GitHubReviewer` (issue #70): the same actor-derived
    /// initials/placeholder tint as `Assignee`, plus the carried review `state` the chip badges.
    init(domain reviewer: GitHubReviewer) {
        self.init(login: reviewer.login, initials: reviewer.initials,
                  color: reviewer.isBot ? agentAccent : Status.purple,
                  avatarURL: reviewer.avatarURL, state: reviewer.state)
    }

    /// Whether this reviewer's request is still pending — the only state that can be cancelled via
    /// `DELETE …/requested_reviewers`, so only these chips offer a remove ✕.
    var isPending: Bool { state == .pending }

    /// The review-state badge the chip shows: a glyph + label, tinted to the verdict (approved →
    /// green, changes requested → red, the rest neutral/amber). Pure presentation glue.
    var stateBadge: (text: String, color: NSColor) {
        switch state {
        case .pending:          return ("⧖ Pending", Status.yellow)
        case .approved:         return ("✓ Approved", Status.green)
        case .changesRequested: return ("✗ Changes requested", Status.red)
        case .commented:        return ("💬 Commented", Status.dim)
        case .dismissed:        return ("⊘ Dismissed", Status.dim)
        }
    }
}

extension LabelChoice {
    /// The edit-picker projection of a repo label: its name plus the hex color resolved to an `NSColor`
    /// (nil → a neutral chip), mirroring how `DetailView.labelPill` tints applied labels.
    init(domain label: GitHubLabel) {
        self.init(name: label.name, color: label.color.flatMap(NSColor.hex(string:)))
    }
}

extension CurrentUser {
    /// Reuse the canonical `GitHubActor.initials` rule (the viewer is just an actor for chip
    /// purposes) so the composer avatar matches how authored comments render. The viewer is never
    /// a bot, so it takes the same `Status.purple` a human comment author gets.
    init(domain u: GitHubUser) {
        self.init(initials: GitHubActor(login: u.login).initials,
                  color: Status.purple,
                  avatarURL: u.avatarURL)
    }
}

extension Comment {
    init(domain c: GitHubComment) {
        let isBot = c.author.isBot
        self.init(author: c.author.login,
                  initials: c.author.initials,
                  color: isBot ? agentAccent : Status.purple,
                  time: GitHubRelativeAge.compact(from: c.createdAt, now: Date()),
                  badge: isBot ? "agent" : "",
                  body: c.body,
                  avatarURL: c.author.avatarURL)
    }
}

extension FileChange {
    init(domain f: GitHubFile) {
        let v = FileChange.visual(for: f.change)
        self.init(path: f.path, glyph: v.glyph, color: v.color, add: f.additions, del: f.deletions)
    }

    /// The single-letter badge + color GitHub uses for each change type (A/M/D/R/C, "~" for a
    /// generic change). Mirrors `Check.visual`.
    private static func visual(for change: GitHubFileChange) -> (glyph: String, color: NSColor) {
        switch change {
        case .added:    return ("A", Status.green)
        case .modified: return ("M", Status.yellow)
        case .removed:  return ("D", Status.red)
        case .renamed:  return ("R", Status.blue)
        case .copied:   return ("C", Status.dim)
        case .changed:  return ("~", Status.dim)
        }
    }
}

extension Check {
    init(domain c: GitHubCheck) {
        let v = Check.visual(for: c.state)
        self.init(name: c.name, icon: v.icon, color: v.color,
                  dur: Check.duration(c.durationSeconds), statusText: v.statusText, running: v.running, url: c.url)
    }

    /// `statusText` says "passed" for success so `DetailView`'s "x/y passing" tally keeps working.
    private static func visual(for state: CheckState) -> (icon: String, color: NSColor, statusText: String, running: Bool) {
        switch state {
        case .success:        return ("✓", Status.green, "passed", false)
        case .inProgress:     return ("●", Status.yellow, "running", true)
        case .queued:         return ("○", Status.dim, "queued", false)
        case .failure:        return ("✕", Status.red, "failed", false)
        case .timedOut:       return ("✕", Status.red, "timed out", false)
        case .cancelled:      return ("⊘", Status.dim, "cancelled", false)
        case .skipped:        return ("⊘", Status.dim, "skipped", false)
        case .actionRequired: return ("!", Status.yellow, "action required", false)
        case .neutral:        return ("•", Status.dim, "neutral", false)
        }
    }

    private static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60, rest = seconds % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m\(rest)s"
    }
}

extension TaskItem {
    init(domain t: GitHubTask) {
        self.init(label: t.title, done: t.isDone)
    }
}
