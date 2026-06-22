import AppKit
import Domain

// Color tokens used by the mock's seed data (theme-independent).
private let P = Status.purple            // epic / roadmap
private let G = Status.green
private let Y = Status.yellow
private let A = NSColor.hex(0x7c8cff)    // agent accent
private let dim = Status.dim

enum ConnKind { case ssh, folder }
enum ItemKind { case issue, pr }

struct Repo { let id, name: String; let open: Int }

struct Org { let id, name: String; let color: NSColor; let repos: [Repo] }

struct Connection {
    let id, name: String
    let kind: ConnKind
    let meta: String
    let dot: NSColor
    let sessionLabel: String
    var isFavorite = false
    var glyph: String { kind == .ssh ? "⧉" : "▦" }
    var kindLabel: String { kind == .ssh ? "SSH" : "FOLDER" }
}

extension Connection {
    /// Presentation projection of a persisted `Domain.Connection`. Live status (dot color,
    /// session label) isn't persisted yet, so a fresh connection reads as idle/dim.
    init(domain c: Domain.Connection) {
        let kind: ConnKind
        let meta: String
        switch c.kind {
        case let .ssh(host, _, _): kind = .ssh; meta = host
        case let .localFolder(path): kind = .folder; meta = path
        }
        self.init(id: c.id.uuidString, name: c.name, kind: kind, meta: meta,
                  dot: Status.dim, sessionLabel: "idle", isFavorite: c.isFavorite)
    }

    /// Shown only in the brief window before the persisted list loads (or if it's empty).
    static let placeholder = Connection(id: "", name: "—", kind: .folder, meta: "",
                                        dot: Status.dim, sessionLabel: "")
}

struct TaskItem { let label: String; let done: Bool }
struct Check { let name, icon: String; let color: NSColor; let dur, statusText: String; var running = false }
struct Comment { let author, initials: String; let color: NSColor; let time, badge, body: String }

struct Item {
    let id, num, title: String
    let kind: ItemKind
    let glyph: String
    let gcolor: NSColor
    let statusLabel: String
    let statusColor: NSColor
    let dotColor: NSColor
    let age, author: String
    let authorColor: NSColor
    let authorInitials: String
    var isAgent = false
    let metaLeft, metaRight: String
    var agentColor: NSColor = dim
    let body: String
    var tasks: [TaskItem] = []
    var checks: [Check] = []
    var comments: [Comment] = []
    var branch: String? = nil
    var add: Int? = nil
    var del: Int? = nil
    var blocked: String? = nil
    var parent: String? = nil
    var epic = false
    var repo = "acme/api-gateway"
}

/// All seed data, faithful to the design mock.
enum Mock {
    static let orgs: [Org] = [
        Org(id: "acme-corp", name: "acme-corp", color: .hex(0x7c8cff), repos: [
            Repo(id: "r1", name: "api-gateway", open: 8),
            Repo(id: "r2", name: "web-dashboard", open: 3),
            Repo(id: "r3", name: "infra", open: 12),
            Repo(id: "r4", name: "mobile-app", open: 2),
        ]),
        Org(id: "opensource", name: "opensource", color: .hex(0xe0823d), repos: [
            Repo(id: "r5", name: "cli", open: 5),
            Repo(id: "r6", name: "sdk-js", open: 1),
        ]),
        Org(id: "ml-lab", name: "ml-lab", color: .hex(0xd2a8ff), repos: [
            Repo(id: "r7", name: "trainer", open: 4),
            Repo(id: "r8", name: "datasets", open: 0),
        ]),
    ]

    static let prs: [Item] = [
        Item(id: "482", num: "#482", title: "Add token-bucket rate limiter to gateway middleware",
             kind: .pr, glyph: "●", gcolor: Y,
             statusLabel: "checks running", statusColor: Y, dotColor: Y,
             age: "4m ago", author: "claude[bot]", authorColor: A, authorInitials: "CL", isAgent: true,
             metaLeft: "⎇ agent/rate-limit", metaRight: "◆ Claude", agentColor: P,
             body: "Implements a token-bucket limiter in the gateway middleware chain. Refill rate and burst size are read from per-route config with a global fallback. Adds table-driven unit tests plus an e2e burst scenario.",
             tasks: [TaskItem(label: "token bucket + refill loop", done: true),
                     TaskItem(label: "per-route config field", done: true),
                     TaskItem(label: "e2e burst scenario (running)", done: false)],
             checks: [Check(name: "CI / build", icon: "✓", color: G, dur: "1m42s", statusText: "passed"),
                      Check(name: "unit · middleware", icon: "✓", color: G, dur: "0.8s", statusText: "passed"),
                      Check(name: "lint", icon: "✓", color: G, dur: "12s", statusText: "passed"),
                      Check(name: "e2e · gateway", icon: "●", color: Y, dur: "51s", statusText: "running", running: true),
                      Check(name: "deploy · preview", icon: "○", color: dim, dur: "queued", statusText: "queued")],
             comments: [Comment(author: "maya", initials: "MA", color: P, time: "12m ago", badge: "",
                                 body: "Nice. Can we make bucket size configurable per route rather than a single global default?"),
                        Comment(author: "claude[bot]", initials: "CL", color: A, time: "8m ago", badge: "agent",
                                body: "Done — added a per-route `burst` field with the global value as fallback. Pushed as a fixup; e2e is re-running.")],
             branch: "agent/rate-limit", add: 214, del: 31),
        Item(id: "478", num: "#478", title: "Cache auth tokens in middleware layer",
             kind: .pr, glyph: "✓", gcolor: G,
             statusLabel: "approved", statusColor: G, dotColor: G,
             age: "1h ago", author: "maya", authorColor: P, authorInitials: "MA",
             metaLeft: "⎇ feat/auth-cache", metaRight: "review", body: "Memoizes verified JWTs for their TTL.",
             branch: "feat/auth-cache", add: 86, del: 12),
        Item(id: "471", num: "#471", title: "Bump gateway base image to bookworm",
             kind: .pr, glyph: "●", gcolor: Y,
             statusLabel: "changes requested", statusColor: Y, dotColor: Y,
             age: "3h ago", author: "sam", authorColor: G, authorInitials: "SM",
             metaLeft: "⎇ chore/base-image", metaRight: "review", body: "Updates the base image and CI runners.",
             branch: "chore/base-image", add: 4, del: 4),
    ]

    static let issues: [Item] = [
        Item(id: "440", num: "#440", title: "Navigation & search overhaul",
             kind: .issue, glyph: "◆", gcolor: P,
             statusLabel: "epic", statusColor: P, dotColor: P,
             age: "3w ago", author: "maya", authorColor: P, authorInitials: "MA",
             metaLeft: "epic · 4 sub-issues", metaRight: "roadmap",
             body: "Umbrella for the command-palette and fuzzy-search rework: a faster scoring matcher, an fzf-style finder, and the keybinding help overlay. Tracks four sub-issues.",
             tasks: [TaskItem(label: "#435 Core scoring matcher", done: true),
                     TaskItem(label: "#408 fzf-style fuzzy finder", done: false),
                     TaskItem(label: "#401 Notifications panel stale counts", done: false),
                     TaskItem(label: "#389 Document keybindings", done: false)],
             epic: true),
        Item(id: "435", num: "#435", title: "Core scoring matcher for fuzzy search",
             kind: .issue, glyph: "●", gcolor: G,
             statusLabel: "in progress", statusColor: Y, dotColor: G,
             age: "5d ago", author: "claude[bot]", authorColor: A, authorInitials: "CL", isAgent: true,
             metaLeft: "feat · in progress", metaRight: "◆ Claude", agentColor: P,
             body: "Implements the core scoring matcher that ranks candidates for the command palette and fuzzy finder.",
             parent: "440"),
        Item(id: "408", num: "#408", title: "fzf-style fuzzy finder",
             kind: .issue, glyph: "○", gcolor: dim,
             statusLabel: "blocked", statusColor: Status.red, dotColor: dim,
             age: "1w ago", author: "sam", authorColor: G, authorInitials: "SM",
             metaLeft: "feat · blocked", metaRight: "",
             body: "Interactive finder UI built on top of the scoring matcher.",
             blocked: "blocked by #435", parent: "440"),
        Item(id: "401", num: "#401", title: "Notifications panel shows stale counts",
             kind: .issue, glyph: "○", gcolor: dim,
             statusLabel: "open", statusColor: dim, dotColor: dim,
             age: "2w ago", author: "maya", authorColor: P, authorInitials: "MA",
             metaLeft: "bug", metaRight: "", body: "Counts don't refresh after marking items read.",
             parent: "440"),
    ]

    static var allItems: [Item] { prs + issues }
    static func item(id: String) -> Item? { allItems.first { $0.id == id } }
}
