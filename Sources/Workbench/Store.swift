import AppKit
import Application
import Domain

/// Shared UI state for the Workbench. Views register an `observe` closure that
/// fires on any data/theme change (used to re-apply content + colors).
final class Store {
    enum Tab { case prs, issues }
    enum GroupBy: String, CaseIterable {
        case none = "Flat list"
        case parent = "By parent"
        case blocked = "By blocked-by"
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
    var tab: Tab = .prs { didSet { if oldValue != tab { notify() } } }
    var groupBy: GroupBy = .none { didSet { if oldValue != groupBy { notify() } } }
    var viewMenuOpen = false { didSet { if oldValue != viewMenuOpen { notify() } } }
    var settingsOpen = false { didSet { if oldValue != settingsOpen { notify() } } }
    var newConnectionOpen = false { didSet { if oldValue != newConnectionOpen { notify() } } }
    var manageOrgsOpen = false { didSet { if oldValue != manageOrgsOpen { notify() } } }
    var authState: AuthState = .signedOut { didSet { if oldValue != authState { notify() } } }

    var selectedConnId = "" { didSet { if oldValue != selectedConnId { changed() } } }
    var selectedItemId = "" { didSet { if oldValue != selectedItemId { changed() } } }
    var expandedOrgs: Set<String> = [] { didSet { notify() } }
    /// The orgs the user follows in the panel, as an ordered list of `Org.id`s. `nil` means the
    /// list was never customized — show every org GitHub returns (see `visibleOrgs`). Persisted.
    var followedOrgs: [String]? { didSet { if oldValue != followedOrgs { changed() } } }

    /// Live GitHub data, fetched by `GitHubDataController` after sign-in and projected onto the
    /// presentation structs the views render. Empty until the first fetch lands (or after sign-out).
    var orgs: [Org] = [] { didSet { notify() } }
    var prs: [Item] = [] { didSet { notify() } }
    var issues: [Item] = [] { didSet { notify() } }
    /// The currently-selected repo as `owner/name`, shown in the titlebar/header; nil before a
    /// repo is picked. Drives which `prs`/`issues` the panel lists.
    var selectedRepoKey: String? { didSet { if oldValue != selectedRepoKey { notify() } } }
    /// The fully-hydrated item (body tasks, comments, PR checks) for the open detail pane. Lead
    /// list items render immediately; this upgrades them once the detail fetch completes.
    var selectedItemDetail: Item? { didSet { notify() } }
    /// A user-facing message when a fetch fails (e.g. signed out, rate-limited); nil when healthy.
    var dataError: String? { didSet { notify() } }
    /// The authenticated viewer, set by `GitHubDataController.load()` and cleared on sign-out. Not
    /// persisted (recomputed from the token at launch, like `authState`). Drives the composer avatar.
    var currentUser: Domain.GitHubUser? { didSet { notify() } }
    /// Transient first-load flags: a region shows a spinner while its fetch is in flight *and* its
    /// collection is still empty, so a refresh over existing data never flashes one. Not persisted.
    var isLoadingOrgs = false { didSet { if oldValue != isLoadingOrgs { notify() } } }
    var isLoadingItems = false { didSet { if oldValue != isLoadingItems { notify() } } }
    var isLoadingDetail = false { didSet { if oldValue != isLoadingDetail { notify() } } }

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

    var listItems: [Item] { tab == .prs ? prs : issues }

    /// The orgs shown in the panel, in the user's chosen order. Derived from the fetched `orgs`
    /// and the persisted `followedOrgs` choice via the pure `OrgFollowing` rule, so the panel and
    /// the manage sheet agree on what's visible.
    var visibleOrgs: [Org] {
        let order = OrgFollowing.visible(available: orgs.map(\.id), followed: followedOrgs)
        let byId = Dictionary(orgs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byId[$0] }
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
            followedOrgs: followedOrgs)
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
        isLoading = false
        onWindowAlpha?(windowAlpha)
        refresh()
    }

    /// Force a content refresh (e.g., after the terminal view is attached).
    func refresh() { notify() }
}
