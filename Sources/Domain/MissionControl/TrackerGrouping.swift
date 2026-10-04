import Foundation

/// An issue/PR as the Mission Control tracker sees it. `needsYou` is true when a session linked
/// to it rang the bell.
public struct TrackerEntry: Sendable, Equatable {
    public let key: String
    public let isPullRequest: Bool
    public let isDraft: Bool
    public let isAgent: Bool
    public let needsYou: Bool

    public init(key: String, isPullRequest: Bool, isDraft: Bool = false, isAgent: Bool = false,
                needsYou: Bool = false) {
        self.key = key
        self.isPullRequest = isPullRequest
        self.isDraft = isDraft
        self.isAgent = isAgent
        self.needsYou = needsYou
    }
}

/// The tracker rail's sections, in display order.
public enum TrackerGroupKind: String, Sendable, CaseIterable {
    case needsYou, agentPullRequests, pullRequests, draftPullRequests, issues
}

/// The board's columns, in display order.
public enum TrackerBoardColumn: String, Sendable, CaseIterable {
    case issues, drafts, ready, agent
}

public struct TrackerGroup: Sendable, Equatable {
    public let kind: TrackerGroupKind
    public let entries: [TrackerEntry]
}

/// Sorts tracker entries into rail sections and board columns. Every entry lands in exactly one
/// section: the first rule it matches in `TrackerGroupKind` order.
public enum TrackerGrouping {

    /// Rail sections in `TrackerGroupKind` order, empty ones dropped, entries in input order.
    public static func groups(_ entries: [TrackerEntry]) -> [TrackerGroup] {
        TrackerGroupKind.allCases.compactMap { kind in
            let members = entries.filter { section(for: $0) == kind }
            return members.isEmpty ? nil : TrackerGroup(kind: kind, entries: members)
        }
    }

    public static func section(for entry: TrackerEntry) -> TrackerGroupKind {
        if entry.needsYou { return .needsYou }
        guard entry.isPullRequest else { return .issues }
        if entry.isAgent { return .agentPullRequests }
        return entry.isDraft ? .draftPullRequests : .pullRequests
    }

    /// The board column for an entry. Unlike the rail, the board has no "needs you" column.
    public static func column(for entry: TrackerEntry) -> TrackerBoardColumn {
        guard entry.isPullRequest else { return .issues }
        if entry.isAgent { return .agent }
        return entry.isDraft ? .drafts : .ready
    }

    /// Every board column, in order, including empty ones (the board keeps a fixed shape).
    public static func board(_ entries: [TrackerEntry]) -> [(column: TrackerBoardColumn, entries: [TrackerEntry])] {
        TrackerBoardColumn.allCases.map { column in
            (column, entries.filter { self.column(for: $0) == column })
        }
    }
}
