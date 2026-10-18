import Foundation

/// What a terminal session is doing, as Mission Control colors it.
public enum MissionTileActivity: Sendable, Equatable {
    /// Nothing in flight.
    case idle
    /// The surface reports work in progress (see `TerminalBusyPolicy`).
    case working
    /// The session rang the bell or posted a notification — it wants the user.
    case attention
    /// The session finished work while the user looked elsewhere (#103). Cleared when its tile gets
    /// focus. Only produced while "Highlight activity" is on.
    case done
}

/// One terminal session as Mission Control sees it. `repoKey` is the `owner/name` of the linked
/// item's repo, nil when the session is unlinked.
public struct MissionTile: Sendable, Equatable {
    public let id: String
    public let title: String
    public let activity: MissionTileActivity
    public let linkedItemKey: String?
    public let repoKey: String?

    public init(id: String, title: String, activity: MissionTileActivity,
                linkedItemKey: String? = nil, repoKey: String? = nil) {
        self.id = id
        self.title = title
        self.activity = activity
        self.linkedItemKey = linkedItemKey
        self.repoKey = repoKey
    }
}

/// Which tiles Mission Control shows and how they group — shared by every mode.
public enum MissionTilePolicy {

    /// A session's activity. Attention wins over working: a session that rang while busy still
    /// needs the user. `done` (finished, not yet seen) only shows when nothing else is going on.
    public static func activity(busy: Bool, bell: Bool, done: Bool = false) -> MissionTileActivity {
        if bell { return .attention }
        if busy { return .working }
        return done ? .done : .idle
    }

    /// The tiles to show, in input order: kept by repo scope (nil = every repo) and activity
    /// filter. There is no cap — a grid that doesn't fit scrolls, so no session ever disappears.
    public static func visible(_ tiles: [MissionTile], filter: MissionFilter, repoKey: String?) -> [MissionTile] {
        let scoped = tiles.filter { tile in
            guard let repoKey else { return true }
            return tile.repoKey == repoKey
        }
        return scoped.filter { tile in
            switch filter {
            case .all: return true
            case .working: return tile.activity == .working
            case .attention: return tile.activity == .attention
            }
        }
    }

    /// The tile keyboard focus should sit on: `current` while it's still visible, else the first
    /// visible tile (nil when nothing is visible). Keeps focus from landing on a hidden tile, which
    /// would drop the keyboard.
    public static func focusAfterFilter(current: String?, visible: [String]) -> String? {
        if let current, visible.contains(current) { return current }
        return visible.first
    }

    /// Tiles ordered by linked repo for "group by repo": repos in `repoOrder` first (others after, by
    /// first appearance), unlinked tiles last. Order within a repo is kept.
    public static func orderedByRepo(_ tiles: [MissionTile], repoOrder: [String]) -> [MissionTile] {
        var keys: [String] = repoOrder
        for tile in tiles {
            if let key = tile.repoKey, !keys.contains(key) { keys.append(key) }
        }
        return keys.flatMap { key in tiles.filter { $0.repoKey == key } } + tiles.filter { $0.repoKey == nil }
    }

    /// How many tiles are in each filter bucket — the counts shown on the filter control.
    public static func counts(_ tiles: [MissionTile]) -> (all: Int, working: Int, attention: Int) {
        (tiles.count, tiles.filter { $0.activity == .working }.count, tiles.filter { $0.activity == .attention }.count)
    }

    /// The focus index after moving `delta` steps, wrapping around `count` tiles. 0 when empty.
    public static func cycle(focus: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(0, focus), count - 1)
        return ((clamped + delta) % count + count) % count
    }

    /// A stored focus index clamped into range for `count` tiles. 0 when empty.
    public static func clampFocus(_ focus: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, focus), count - 1)
    }
}
