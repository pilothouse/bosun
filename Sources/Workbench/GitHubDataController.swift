import Application
import Domain
import Foundation

/// Thin App-layer controller that drives the live GitHub data into `Store`. It calls the
/// `GitHubAPI` use case and projects the Domain results onto the presentation structs the views
/// read, mapping failures onto `Store.dataError`. `@MainActor` because it only ever mutates
/// `Store` (main-thread UI state); it owns its `Task`s so a repo/item switch cancels stale fetches
/// and out-of-order responses are dropped. Mirrors `GitHubAuthController`.
@MainActor
final class GitHubDataController {
    private let api: GitHubAPI
    private let store: Store

    private var loadTask: Task<Void, Never>?
    private var itemsTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    /// The repo whose items are currently shown, so an item-detail fetch knows its owner/name and
    /// late responses for a previous repo can be ignored.
    private var currentRepo: (owner: String, name: String)?

    init(api: GitHubAPI, store: Store) {
        self.api = api
        self.store = store
    }

    /// Fetch the viewer's orgs/repos after sign-in, expand the first org, and load the first
    /// repo's items. Safe to call again — it cancels any in-flight load first.
    func load() {
        loadTask?.cancel()
        store.dataError = nil
        store.isLoadingOrgs = true
        loadTask = Task { @MainActor in
            do {
                // Orgs and the viewer's own repos load together; the personal repos surface as a
                // synthetic group pinned at the top so a no-org account still sees live data.
                async let orgsCall = api.organizations()
                async let personalCall = api.viewerRepositories()
                let (orgs, personalRepos) = try await (orgsCall, personalCall)
                var groups = orgs.map(Org.init(domain:))
                if let personal = Org(personalRepos: personalRepos) { groups.insert(personal, at: 0) }
                store.orgs = groups
                store.isLoadingOrgs = false
                // Honor the user's followed/ordered choice for the initial expand + selection, so a
                // hidden org never steals focus on launch.
                guard let firstOrg = store.visibleOrgs.first else { clearItems(); return }
                store.expandedOrgs = [firstOrg.id]
                if let firstRepo = firstOrg.repos.first {
                    selectRepo(owner: firstRepo.owner, name: firstRepo.name)
                } else {
                    clearItems()
                }
            } catch {
                handle(error)
                // A cancelled load means a newer load() already owns the spinner — leave it on.
                if !Task.isCancelled { store.isLoadingOrgs = false }
            }
            loadTask = nil
        }
    }

    /// Switch the active repo: update the breadcrumb/header and reload its PRs and issues.
    func selectRepo(owner: String, name: String) {
        currentRepo = (owner, name)
        store.selectedRepoKey = "\(owner)/\(name)"
        loadItems(owner: owner, name: name)
    }

    /// Select a list item: show its lead content immediately (the store already has it) and
    /// fetch the hydrated detail (body tasks, comments, PR checks) to upgrade it.
    func selectItem(number: Int) {
        guard let repo = currentRepo else { return }
        store.selectedItemId = String(number)
        store.selectedItemDetail = nil
        loadDetail(owner: repo.owner, name: repo.name, number: number)
    }

    /// Drop all live data on sign-out so the UI returns to an empty, signed-out shell.
    func clear() {
        loadTask?.cancel(); itemsTask?.cancel(); detailTask?.cancel()
        currentRepo = nil
        store.orgs = []
        store.expandedOrgs = []
        store.selectedRepoKey = nil
        clearItems()
        store.dataError = nil
        // Cancelled tasks won't reach their ownership-guarded clears, so reset here.
        store.isLoadingOrgs = false
        store.isLoadingItems = false
        store.isLoadingDetail = false
    }

    // MARK: - Private

    private func loadItems(owner: String, name: String) {
        itemsTask?.cancel()
        detailTask?.cancel()
        store.dataError = nil
        store.isLoadingItems = true
        itemsTask = Task { @MainActor in
            // Only the task whose repo is still the current one owns the spinner: a stale/cancelled
            // response for a superseded repo must not clear the flag the newer fetch just set.
            @MainActor func isCurrent() -> Bool { currentRepo?.owner == owner && currentRepo?.name == name }
            do {
                async let prs = api.items(owner: owner, repo: name, kind: .pullRequest)
                async let issues = api.items(owner: owner, repo: name, kind: .issue)
                let (prItems, issueItems) = try await (prs, issues)
                // Ignore a response that landed after the user switched repos.
                guard isCurrent() else { return }
                store.prs = prItems.map(Item.init(domain:))
                store.issues = issueItems.map(Item.init(domain:))
                store.isLoadingItems = false
                reconcileSelection(owner: owner, name: name)
            } catch {
                handle(error)
                if isCurrent() { store.isLoadingItems = false }
            }
            itemsTask = nil
        }
    }

    /// Keep the open item valid for the freshly-loaded list: re-hydrate it if it's still present,
    /// otherwise default to the first item of the active tab (PRs, else issues).
    private func reconcileSelection(owner: String, name: String) {
        if store.listItems.contains(where: { $0.id == store.selectedItemId }),
           let number = Int(store.selectedItemId) {
            store.selectedItemDetail = nil
            loadDetail(owner: owner, name: name, number: number)
            return
        }
        let fallback = store.listItems.first ?? store.prs.first ?? store.issues.first
        store.selectedItemDetail = nil
        guard let first = fallback, let number = Int(first.id) else {
            store.selectedItemId = ""
            return
        }
        store.selectedItemId = first.id
        loadDetail(owner: owner, name: name, number: number)
    }

    private func loadDetail(owner: String, name: String, number: Int) {
        detailTask?.cancel()
        store.isLoadingDetail = true
        detailTask = Task { @MainActor in
            // The still-current selection owns the spinner; a stale detail leaves it on for the
            // newer fetch.
            @MainActor func isCurrent() -> Bool {
                store.selectedItemId == String(number)
                    && currentRepo?.owner == owner && currentRepo?.name == name
            }
            do {
                let detail = try await api.itemDetail(owner: owner, repo: name, number: number)
                // Drop a stale detail if the selection moved on while this was in flight.
                guard isCurrent() else { return }
                store.selectedItemDetail = Item(domain: detail)
                store.isLoadingDetail = false
            } catch {
                // A detail failure is non-fatal: the lead list item keeps showing, so don't blow
                // away the whole pane with a global error — just log it.
                if !(error is CancellationError) {
                    NSLog("[github-data] detail #\(number) failed: \(error)")
                    if isCurrent() { store.isLoadingDetail = false }
                }
            }
            detailTask = nil
        }
    }

    private func clearItems() {
        store.prs = []
        store.issues = []
        store.selectedItemId = ""
        store.selectedItemDetail = nil
    }

    private func handle(_ error: Error) {
        if error is CancellationError { return }
        store.dataError = Self.message(for: error)
    }

    private static func message(for error: Error) -> String {
        guard let apiError = error as? GitHubAPIError else {
            return "Couldn't load GitHub data. Please try again."
        }
        switch apiError {
        case .unauthorized: return "Your GitHub session expired. Sign in again to load data."
        case .rateLimited:  return "GitHub rate limit reached. Try again in a little while."
        case .notFound:     return "That repository or item is no longer available."
        case .http, .decoding, .transport:
            return "Couldn't reach GitHub. Check your connection and try again."
        }
    }
}
