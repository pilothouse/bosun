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
    /// How the issue/PR list is sorted: the field as an opaque `ItemSortField` key the App layer maps
    /// to its enum (`nil` means never customized — sort by date), and the direction (`false` means
    /// descending, the newest-first default for date). See `ItemSorting`.
    public var sortField: String?
    public var sortAscending: Bool
    /// The lifecycle states the PR and issue lists are filtered to, as `GitHubItemState` raw values
    /// (`"open"`/`"closed"`/`"merged"`). `nil` means never customized — default to open-only, the
    /// cheap fast path. See `GitHubItemStates` for how these drive both the fetch and the display.
    public var prStates: [String]?
    public var issueStates: [String]?
    /// The open terminal tabs and which one was active, reopened on relaunch. `nil` means never
    /// saved — seed a single local shell (today's behaviour). The active tab is keyed by its saved
    /// `TerminalTabState.id` (not a positional index) so restore picks the right tab even when an
    /// earlier tab is dropped (a deleted connection). See `TerminalTabState`.
    public var openTabs: [TerminalTabState]?
    public var activeTabId: String?
    /// Whether the PR detail pane's `ACTIONS` (CI checks) section is collapsed. Global — one
    /// app-wide preference shared across every PR, not per-PR. `false` (expanded) by default.
    public var prChecksCollapsed: Bool
    /// Whether the org panel hides repos with zero open issues+PRs. `false` (show every repo) by
    /// default — the user opts in to declutter. "Empty" is open-only; see `RepoVisibility`.
    public var skipEmptyRepos: Bool

    /// The lowest opacity we let the window reach — below this the chrome is unusable.
    public static let minAlpha: Double = 0.3

    /// Exponent of the opacity easing curve. >1 flattens the top of the range so a small drag
    /// from fully-opaque barely changes the window. See `windowAlpha(forSliderPosition:)`.
    public static let alphaCurve: Double = 2.2

    /// Maps a slider position in `[0, 1]` (0 = most transparent, 1 = opaque) to a window alpha
    /// in `[minAlpha, 1]`. The curve eases the top of the range — near position 1 the slope is
    /// ~0, so a small move down from opaque is nearly invisible (issue #39) — while the far end
    /// still reaches `minAlpha`. A pure rule, so it stays in Domain and is shared by the slider's
    /// setup, its change handler, and the readout.
    public static func windowAlpha(forSliderPosition position: Double) -> Double {
        let pos = min(1.0, max(0.0, position))
        return clampAlpha(1.0 - (1.0 - minAlpha) * pow(1.0 - pos, alphaCurve))
    }

    /// Inverse of `windowAlpha(forSliderPosition:)` — the slider position that yields a stored
    /// alpha, used to place the knob when the sheet opens and to render the readout.
    public static func sliderPosition(forWindowAlpha alpha: Double) -> Double {
        let clamped = clampAlpha(alpha)
        let ratio = (1.0 - clamped) / (1.0 - minAlpha) // in [0, 1]
        return 1.0 - pow(ratio, 1.0 / alphaCurve)
    }

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
        sortField: String? = nil,
        sortAscending: Bool = false,
        prStates: [String]? = nil,
        issueStates: [String]? = nil,
        openTabs: [TerminalTabState]? = nil,
        activeTabId: String? = nil,
        prChecksCollapsed: Bool = false,
        skipEmptyRepos: Bool = false
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
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.prStates = prStates
        self.issueStates = issueStates
        self.openTabs = openTabs
        self.activeTabId = activeTabId
        self.prChecksCollapsed = prChecksCollapsed
        self.skipEmptyRepos = skipEmptyRepos
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
            sortField: try container.decodeIfPresent(String.self, forKey: .sortField) ?? fallback.sortField,
            sortAscending: try container.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? fallback.sortAscending,
            prStates: try container.decodeIfPresent([String].self, forKey: .prStates) ?? fallback.prStates,
            issueStates: try container.decodeIfPresent([String].self, forKey: .issueStates) ?? fallback.issueStates,
            openTabs: try container.decodeIfPresent([TerminalTabState].self, forKey: .openTabs) ?? fallback.openTabs,
            activeTabId: try container.decodeIfPresent(String.self, forKey: .activeTabId) ?? fallback.activeTabId,
            prChecksCollapsed: try container.decodeIfPresent(Bool.self, forKey: .prChecksCollapsed) ?? fallback.prChecksCollapsed,
            skipEmptyRepos: try container.decodeIfPresent(Bool.self, forKey: .skipEmptyRepos) ?? fallback.skipEmptyRepos
        )
    }

    private static func clampAlpha(_ value: Double) -> Double {
        min(1.0, max(minAlpha, value))
    }
}
