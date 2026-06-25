import AppKit
import Application
import Domain

/// Shared UI state for Bosun. Views register an `observe` closure that
/// fires on any data/theme change (used to re-apply content + colors).
final class Store {
    enum Tab: String { case prs, issues }   // rawValue is the stable persistence key
    enum GroupBy: String, CaseIterable {
        case none = "Flat list"
        case parent = "By parent"
        case blocked = "By blocked-by"

        /// Stable key for persistence, independent of the display `rawValue` above (so renaming a
        /// label never invalidates a stored value). See `Preferences.groupBy`.
        var storageKey: String {
            switch self { case .none: "none"; case .parent: "parent"; case .blocked: "blocked" }
        }
        init(storageKey: String?) {
            switch storageKey {
            case "parent": self = .parent
            case "blocked": self = .blocked
            default: self = .none
            }
        }
    }

    /// GitHub sign-in state. Deliberately NOT persisted in `Preferences` — the token lives in the
    /// Keychain, and this is recomputed at launch from `GitHubTokenStore.load()`. It drives the
    /// device-flow overlay (the authenticating cases) and the Settings "Account" section.
    enum AuthState: Equatable {
        case signedOut
        case authenticatingPending                  // sheet open, device code not yet returned
        case authenticating(Domain.DeviceCodeGrant) // device code issued; user is entering it
        case signedIn
        case authError(String)                      // request/poll failed; sheet shows the reason
    }

    var themeKey = "operator" { didSet { if oldValue != themeKey { changed() } } }
    var theme: Theme { Theme.named(themeKey) }

    var railCollapsed = false { didSet { if oldValue != railCollapsed { notify() } } }
    /// Whether the right organizations panel is collapsed. Session-only (mirrors `railCollapsed`):
    /// a `notify()` so the toggle slides without persisting, matching the left-rail behavior.
    var repoPanelCollapsed = false { didSet { if oldValue != repoPanelCollapsed { notify() } } }
    /// Whether the PR detail's `ACTIONS` (CI checks) section is collapsed. Global and persisted
    /// (the `groupBy` precedent), so a change repaints the open PR and survives relaunch, shared
    /// across every PR.
    var prChecksCollapsed = false { didSet { if oldValue != prChecksCollapsed { changed() } } }
    /// Whether the org panel hides repos with zero open issues+PRs. Global, persisted; a change
    /// re-filters every org's repos instantly via `visibleOrgs`. Off (show all) by default.
    var skipEmptyRepos = false { didSet { if oldValue != skipEmptyRepos { changed() } } }
    /// The active item tab and the list grouping ("View"). Persisted, so they're restored on relaunch
    /// (the restored item's kind can still flip the tab — see `GitHubDataController.reconcileSelection`).
    var tab: Tab = .prs { didSet { if oldValue != tab { changed() } } }
    var groupBy: GroupBy = .none { didSet { if oldValue != groupBy { changed() } } }
    /// How each org's repos are ordered in the panel (by name, or busiest-first by open issue+PR
    /// count). Global, persisted; a change re-sorts every org's repos instantly via `visibleOrgs`.
    var repoOrdering: RepoOrderingMode = .byName { didSet { if oldValue != repoOrdering { changed() } } }
    /// The lifecycle states the PR and issue lists are filtered to (and fetched for). Default
    /// open-only — the cheap fast path. Persisted; a change re-filters the list instantly and
    /// triggers a re-fetch in the matching scope (see `GitHubDataController.reloadCurrentItems`).
    var prStates: Set<GitHubItemState> = [.open] { didSet { if oldValue != prStates { changed() } } }
    var issueStates: Set<GitHubItemState> = [.open] { didSet { if oldValue != issueStates { changed() } } }
    var viewMenuOpen = false { didSet { if oldValue != viewMenuOpen { notify() } } }
    var statusMenuOpen = false { didSet { if oldValue != statusMenuOpen { notify() } } }
    /// Window-coordinate rects of an open dropdown's menu and its toggle buttons — the regions where
    /// a click must NOT dismiss the menu. Published by `RepoPanelView` each rebuild and read by the
    /// window's `sendEvent` to dismiss the dropdown on a click anywhere else. Not persisted.
    var menuDismissRects: [CGRect] = []
    var settingsOpen = false { didSet { if oldValue != settingsOpen { notify() } } }
    var newConnectionOpen = false { didSet { if oldValue != newConnectionOpen { notify() } } }
    var manageOrgsOpen = false { didSet { if oldValue != manageOrgsOpen { notify() } } }
    var authState: AuthState = .signedOut { didSet { if oldValue != authState { notify() } } }

    var selectedConnId = "" { didSet { if oldValue != selectedConnId { changed() } } }
    var selectedItemId = "" { didSet { if oldValue != selectedItemId { changed() } } }
    var expandedOrgs: Set<String> = [] { didSet { notify() } }
    /// Item ids (issue/PR numbers as strings) whose subtree is collapsed in the grouped list. A
    /// session-only UI toggle — not persisted, and reset when the repo changes (a stale number
    /// would otherwise hide an unrelated item in the next repo). See `RepoPanelView` grouped render.
    var collapsedItems: Set<String> = [] { didSet { notify() } }
    /// The orgs the user follows in the panel, as an ordered list of `Org.id`s. `nil` means the
    /// list was never customized — show every org GitHub returns (see `visibleOrgs`). Persisted.
    var followedOrgs: [String]? { didSet { if oldValue != followedOrgs { changed() } } }

    /// Live GitHub data, fetched by `GitHubDataController` after sign-in and projected onto the
    /// presentation structs the views render. Empty until the first fetch lands (or after sign-out).
    var orgs: [Org] = [] { didSet { notify() } }
    var prs: [Item] = [] { didSet { notify() } }
    var issues: [Item] = [] { didSet { notify() } }
    /// The currently-selected repo as `owner/name`, shown in the titlebar/header; nil before a
    /// repo is picked. Drives which `prs`/`issues` the panel lists. Persisted, so the selection is
    /// restored on relaunch (see `GitHubDataController.applyOrgGroups` and `RepoSelection`).
    var selectedRepoKey: String? { didSet { if oldValue != selectedRepoKey { changed() } } }
    /// The fully-hydrated item (body tasks, comments, PR checks) for the open detail pane. Lead
    /// list items render immediately; this upgrades them once the detail fetch completes.
    var selectedItemDetail: Item? { didSet { notify() } }
    /// A user-facing message when a fetch fails (e.g. signed out, rate-limited); nil when healthy.
    var dataError: String? { didSet { notify() } }
    /// Why the device-flow sheet was opened, when sign-in was *forced* by an expired/revoked token
    /// (vs. a user-initiated sign-in, which leaves this nil and shows no subtitle). Set by the auth
    /// controller's recovery; the sheet renders it under the title. Not persisted.
    var signInReason: String? { didSet { notify() } }
    /// The authenticated viewer, set by `GitHubDataController.load()` and cleared on sign-out. Not
    /// persisted (recomputed from the token at launch, like `authState`). Drives the composer avatar.
    var currentUser: Domain.GitHubUser? { didSet { notify() } }
    /// Transient first-load flags: a region shows a spinner while its fetch is in flight *and* its
    /// collection is still empty, so a refresh over existing data never flashes one. Not persisted.
    var isLoadingOrgs = false { didSet { if oldValue != isLoadingOrgs { notify() } } }
    var isLoadingItems = false { didSet { if oldValue != isLoadingItems { notify() } } }
    var isLoadingDetail = false { didSet { if oldValue != isLoadingDetail { notify() } } }
    /// A user-initiated global refresh is in flight. Unlike the flags above (which only gate the
    /// cold-start spinner and stay false on a warm refresh over existing data), this stays true for
    /// the whole refresh so the orgs-panel button can show a spinner and ignore repeat clicks.
    var isRefreshing = false { didSet { if oldValue != isRefreshing { notify() } } }
    /// Whether the last PR/issue fetch bounded its closed/merged history (older items not loaded),
    /// so the panel can surface the cap. Transient, not persisted — recomputed on every fetch.
    var prsTruncated = false { didSet { if oldValue != prsTruncated { notify() } } }
    var issuesTruncated = false { didSet { if oldValue != issuesTruncated { notify() } } }

    /// Window opacity. It drives the window directly (via `onWindowAlpha`) rather than a content
    /// rebuild, so it is deliberately not part of `notify` — otherwise dragging the opacity
    /// slider would tear down and rebuild the Settings popover under the cursor.
    var windowAlpha: CGFloat = 1.0 {
        didSet {
            guard !isLoading, oldValue != windowAlpha else { return }
            onWindowAlpha?(windowAlpha)
            persist()
        }
    }
    /// Set by the App layer to apply opacity to the live `NSWindow`.
    var onWindowAlpha: ((CGFloat) -> Void)?

    /// Persisted connections (source of truth), loaded from the store at launch and mutated by
    /// the New-connection flow. The id of the connection the sheet is editing (nil = adding).
    var domainConnections: [Domain.Connection] = [] { didSet { notify() } }
    var editingConnId: String?

    /// Terminal height drives layout only (no content rebuild), so it is not part of `notify`.
    /// It changes on every drag frame, so it is persisted on gesture end (see
    /// `TerminalContainerView`), not here.
    var terminalHeight: CGFloat = 240

    /// The open terminal tabs and which one is active, owned by the dock (`TerminalContainerView`):
    /// it snapshots them here on every tab change and restores them at launch. Persisted, but not
    /// part of `notify` — the dock manages its own views, so a write here must not rebuild the UI.
    var terminalTabs: [Domain.TerminalTabState] = []
    /// The active tab keyed by its saved `TerminalTabState.id` (not a positional index), so restore
    /// survives an earlier tab being dropped. `nil` until the dock first snapshots.
    var activeTerminalTabId: String?

    /// Persistence seam for UI preferences (loaded at launch, saved on change).
    private let preferences: PreferencesStore
    /// True while `applyPersisted` is restoring state, so the property observers don't re-save
    /// the values we just loaded or rebuild the UI field-by-field.
    private var isLoading = false

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    /// The signed-in viewer projected for the composer avatar; nil until the first fetch lands or
    /// after sign-out (the composer falls back to a neutral placeholder dot).
    var viewer: CurrentUser? { currentUser.map(CurrentUser.init(domain:)) }

    /// Presentation projections the rail/header read from.
    var connections: [Connection] { domainConnections.map(Connection.init(domain:)) }
    var favorites: [Connection] { connections.filter { $0.isFavorite } }
    var sshRemotes: [Connection] { connections.filter { $0.kind == .ssh } }
    var folders: [Connection] { connections.filter { $0.kind == .folder } }

    var selectedConn: Connection {
        connections.first { $0.id == selectedConnId } ?? connections.first ?? .placeholder
    }

    /// The hydrated detail when it matches the selection, else the lead list item — so the pane
    /// shows the row's content instantly and fills in comments/checks when the detail fetch lands.
    var selectedItem: Item? {
        if let detail = selectedItemDetail, detail.id == selectedItemId { return detail }
        return (prs + issues).first { $0.id == selectedItemId }
    }

    /// The fetched lists narrowed to the user's selected states (the instant display filter). The
    /// fetch scope tracks the same selection, so this only differs transiently — while a re-fetch
    /// for a just-changed selection is still in flight against the previously-cached rows.
    var visiblePRs: [Item] { prs.filter { prStates.contains($0.state) } }
    var visibleIssues: [Item] { issues.filter { issueStates.contains($0.state) } }
    var listItems: [Item] { tab == .prs ? visiblePRs : visibleIssues }

    /// Whether the active tab's list bounded its closed/merged history, for the panel's footer note.
    var listTruncated: Bool { tab == .prs ? prsTruncated : issuesTruncated }

    /// The orgs shown in the panel, in the user's chosen order, each with its repos sorted by the
    /// chosen `repoOrdering`. Derived from the fetched `orgs` and the persisted `followedOrgs`
    /// choice via the pure `OrgFollowing` rule, so the panel and the manage sheet agree on what's
    /// visible — and so the repo sort applies wherever repos are read (the panel render and the
    /// auto-select in `GitHubDataController`), via this one accessor.
    var visibleOrgs: [Org] {
        let order = OrgFollowing.visible(available: orgs.map(\.id), followed: followedOrgs)
        let byId = Dictionary(orgs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mode = repoOrdering
        let skip = skipEmptyRepos
        return order.compactMap { byId[$0] }.map { org in
            let ordered = RepoOrdering.order(org.repos, by: mode, name: \.name, open: \.open)
            let shown = RepoVisibility.visible(ordered, skipEmpty: skip, open: \.open)
            return Org(id: org.id, name: org.name, color: org.color, avatarURL: org.avatarURL,
                       repos: shown)
        }
    }

    /// `owner/name` of the selected repo for the titlebar breadcrumb and panel header.
    var selectedRepoTitle: String { selectedRepoKey ?? "" }

    private var observers: [() -> Void] = []
    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    private func notify() { observers.forEach { $0() } }

    /// A persisted field changed by the user: repaint and save. Suppressed during a restore.
    private func changed() {
        guard !isLoading else { return }
        notify()
        persist()
    }

    /// Snapshot the persisted fields and save them. Called from `changed()` and directly by the
    /// terminal dock at the end of a resize. A no-op while restoring.
    func persist() {
        guard !isLoading else { return }
        let snapshot = Preferences(
            themeKey: themeKey,
            terminalHeight: Double(terminalHeight),
            selectedConnId: selectedConnId,
            selectedItemId: selectedItemId,
            windowAlpha: Double(windowAlpha),
            followedOrgs: followedOrgs,
            selectedRepoKey: selectedRepoKey,
            selectedTab: tab.rawValue,
            groupBy: groupBy.storageKey,
            repoOrdering: repoOrdering.rawValue,
            prStates: prStates.map(\.rawValue).sorted(),
            issueStates: issueStates.map(\.rawValue).sorted(),
            openTabs: terminalTabs.isEmpty ? nil : terminalTabs,
            activeTabId: activeTerminalTabId,
            prChecksCollapsed: prChecksCollapsed,
            skipEmptyRepos: skipEmptyRepos)
        Task { await preferences.save(snapshot) }
    }

    /// Restore saved preferences at launch, then repaint once. Connection-selection validity is
    /// reconciled by the caller against the loaded connection list.
    func applyPersisted(_ p: Preferences) {
        isLoading = true
        themeKey = p.themeKey
        terminalHeight = CGFloat(p.terminalHeight)
        selectedConnId = p.selectedConnId
        selectedItemId = p.selectedItemId
        windowAlpha = CGFloat(p.windowAlpha)
        followedOrgs = p.followedOrgs
        selectedRepoKey = p.selectedRepoKey
        tab = Tab(rawValue: p.selectedTab ?? "") ?? .prs
        groupBy = GroupBy(storageKey: p.groupBy)
        repoOrdering = RepoOrderingMode(rawValue: p.repoOrdering ?? "") ?? .default
        prStates = Store.states(from: p.prStates, default: [.open])
        issueStates = Store.states(from: p.issueStates, default: [.open]).subtracting([.merged])
        terminalTabs = p.openTabs ?? []
        activeTerminalTabId = p.activeTabId
        prChecksCollapsed = p.prChecksCollapsed
        skipEmptyRepos = p.skipEmptyRepos
        isLoading = false
        onWindowAlpha?(windowAlpha)
        refresh()
    }

    /// Force a content refresh (e.g., after the terminal view is attached).
    func refresh() { notify() }

    /// Decode a persisted status selection (raw `GitHubItemState` values), dropping anything
    /// unrecognized and falling back to `default` when nothing valid remains — a stored selection
    /// must never leave a tab filtered to an empty set (a blank list).
    private static func states(from raw: [String]?, default fallback: Set<GitHubItemState>)
        -> Set<GitHubItemState> {
        guard let raw else { return fallback }
        let parsed = Set(raw.compactMap(GitHubItemState.init(rawValue:)))
        return parsed.isEmpty ? fallback : parsed
    }
}
