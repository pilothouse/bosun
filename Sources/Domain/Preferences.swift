import Foundation

/// UI preferences that survive a relaunch: the chosen theme, the docked-terminal height, the
/// last selection (connection + item), and the window opacity. Pure value type — the I/O of
/// reading and writing it lives behind the `PreferencesStore` port and its UserDefaults
/// adapter. Heights and alpha are `Double` (not `CGFloat`) so Domain stays free of
/// CoreGraphics; the App layer converts at the boundary.
public struct Preferences: Sendable, Equatable, Codable {
    public var themeKey: String
    public var terminalHeight: Double
    public var selectedConnId: String
    public var selectedItemId: String
    /// Window opacity, clamped to `[minAlpha, 1.0]` so a stored value can never make the
    /// window invisible and unrecoverable.
    public var windowAlpha: Double
    /// The orgs the user follows in the panel, as an ordered list of org ids. `nil` means the
    /// list was never customized — show every org GitHub returns. An empty array means the user
    /// explicitly hid them all. See `OrgFollowing` for how this drives the visible set.
    public var followedOrgs: [String]?
    /// The last selected repo, as `owner/name`. `nil` means none was remembered — auto-select the
    /// first available repo on launch. On restore, a key the viewer can no longer reach (access
    /// lost or repo gone) falls back to that same auto-selection. See `RepoSelection`.
    public var selectedRepoKey: String?
    /// The active item tab (PRs vs Issues) and the list grouping ("View"), stored as opaque keys
    /// the App layer maps to its own enums. `nil` means never customized — use the default. The
    /// open item's kind can still override the restored tab so the item stays visible.
    public var selectedTab: String?
    public var groupBy: String?
    /// How repos within an org are ordered in the panel, as an opaque `RepoOrderingMode` key the
    /// App layer maps to its enum. `nil` means never customized — order by name. See `RepoOrdering`.
    public var repoOrdering: String?
    /// The lifecycle states the PR and issue lists are filtered to, as `GitHubItemState` raw values
    /// (`"open"`/`"closed"`/`"merged"`). `nil` means never customized — default to open-only, the
    /// cheap fast path. See `GitHubItemStates` for how these drive both the fetch and the display.
    public var prStates: [String]?
    public var issueStates: [String]?
    /// The open terminal tabs and which one was active, reopened on relaunch. `nil` means never
    /// saved — seed a single local shell (today's behaviour). See `TerminalTabState`.
    public var openTabs: [TerminalTabState]?
    public var activeTabIndex: Int?
    /// Whether the PR detail pane's `ACTIONS` (CI checks) section is collapsed. Global — one
    /// app-wide preference shared across every PR, not per-PR. `false` (expanded) by default.
    public var prChecksCollapsed: Bool

    /// The lowest opacity we let the window reach — below this the chrome is unusable.
    public static let minAlpha: Double = 0.3

    public init(
        themeKey: String = "operator",
        terminalHeight: Double = 240,
        selectedConnId: String = "api-gateway",
        selectedItemId: String = "482",
        windowAlpha: Double = 1.0,
        followedOrgs: [String]? = nil,
        selectedRepoKey: String? = nil,
        selectedTab: String? = nil,
        groupBy: String? = nil,
        repoOrdering: String? = nil,
        prStates: [String]? = nil,
        issueStates: [String]? = nil,
        openTabs: [TerminalTabState]? = nil,
        activeTabIndex: Int? = nil,
        prChecksCollapsed: Bool = false
    ) {
        self.themeKey = themeKey
        self.terminalHeight = terminalHeight
        self.selectedConnId = selectedConnId
        self.selectedItemId = selectedItemId
        self.windowAlpha = Preferences.clampAlpha(windowAlpha)
        self.followedOrgs = followedOrgs
        self.selectedRepoKey = selectedRepoKey
        self.selectedTab = selectedTab
        self.groupBy = groupBy
        self.repoOrdering = repoOrdering
        self.prStates = prStates
        self.issueStates = issueStates
        self.openTabs = openTabs
        self.activeTabIndex = activeTabIndex
        self.prChecksCollapsed = prChecksCollapsed
    }

    /// The starting state used on first launch and as the fallback for any missing/corrupt field.
    public static let `default` = Preferences()

    /// Tolerant decoding: a key absent from the stored payload (an older or newer build) decodes
    /// to its default instead of throwing, and the alpha invariant is re-applied.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preferences.default
        self.init(
            themeKey: try container.decodeIfPresent(String.self, forKey: .themeKey) ?? fallback.themeKey,
            terminalHeight: try container.decodeIfPresent(Double.self, forKey: .terminalHeight) ?? fallback.terminalHeight,
            selectedConnId: try container.decodeIfPresent(String.self, forKey: .selectedConnId) ?? fallback.selectedConnId,
            selectedItemId: try container.decodeIfPresent(String.self, forKey: .selectedItemId) ?? fallback.selectedItemId,
            windowAlpha: try container.decodeIfPresent(Double.self, forKey: .windowAlpha) ?? fallback.windowAlpha,
            followedOrgs: try container.decodeIfPresent([String].self, forKey: .followedOrgs) ?? fallback.followedOrgs,
            selectedRepoKey: try container.decodeIfPresent(String.self, forKey: .selectedRepoKey) ?? fallback.selectedRepoKey,
            selectedTab: try container.decodeIfPresent(String.self, forKey: .selectedTab) ?? fallback.selectedTab,
            groupBy: try container.decodeIfPresent(String.self, forKey: .groupBy) ?? fallback.groupBy,
            repoOrdering: try container.decodeIfPresent(String.self, forKey: .repoOrdering) ?? fallback.repoOrdering,
            prStates: try container.decodeIfPresent([String].self, forKey: .prStates) ?? fallback.prStates,
            issueStates: try container.decodeIfPresent([String].self, forKey: .issueStates) ?? fallback.issueStates,
            openTabs: try container.decodeIfPresent([TerminalTabState].self, forKey: .openTabs) ?? fallback.openTabs,
            activeTabIndex: try container.decodeIfPresent(Int.self, forKey: .activeTabIndex) ?? fallback.activeTabIndex,
            prChecksCollapsed: try container.decodeIfPresent(Bool.self, forKey: .prChecksCollapsed) ?? fallback.prChecksCollapsed
        )
    }

    private static func clampAlpha(_ value: Double) -> Double {
        min(1.0, max(minAlpha, value))
    }
}
