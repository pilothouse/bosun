import AppKit
import Domain

// The default tint for a non-agent item's right-hand meta (theme-independent).
private let dim = Status.dim

enum ConnKind { case ssh, folder }
enum ItemKind { case issue, pr }

struct Repo { let id, name: String; let open: Int; var owner = "" }

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

/// The signed-in viewer, projected for the comment composer's avatar. Real avatar images are
/// deferred to #25; for now we render the initials `Dot` (mirroring `Comment`). `avatarURL` is
/// carried so #25 can swap in the image without re-plumbing.
struct CurrentUser { let initials: String; let color: NSColor; let avatarURL: URL? }

/// Presentation projection of a GitHub issue/PR. Built from `Domain.GitHubItem` by the mapper in
/// `GitHubPresentation.swift` (colors, glyphs, and relative-time strings live there); the views
/// render straight off these fields. `tasks`/`checks`/`comments` are populated by the detail fetch.
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
    var repo = ""
}
