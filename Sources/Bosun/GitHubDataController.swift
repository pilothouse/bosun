import Application
import Domain
import Foundation

/// Thin App-layer controller that drives the live GitHub data into `Store`. It calls the
/// `GitHubAPI` use case and projects the Domain results onto the presentation structs the views
/// read, mapping failures onto `Store.dataError`. `@MainActor` because it only ever mutates
/// `Store` (main-thread UI state); it owns its `Task`s so a repo/item switch cancels stale fetches
/// and out-of-order responses are dropped. Mirrors `GitHubAuthController`.
///
/// Every fetch is **hydrate-then-delta**: the `GitHubCacheStore` copy is projected into the UI first
/// (instantly, with no spinner), then the live response is diffed against it via `GitHubDelta` and
/// saved back. The spinner shows only on a cold cache, and a refresh that returns identical data
/// leaves the store — and therefore the views — untouched.
@MainActor
final class GitHubDataController {
    private let api: GitHubAPI
    private let cache: GitHubCacheStore
    private let store: Store
    /// The write seam (the app's only mutation). The controller drives it like every other use
    /// case; the view never touches the client directly.
    private let addCommentUseCase: AddCommentUseCase

    private var loadTask: Task<Void, Never>?
    private var itemsTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    /// The repo whose items are currently shown, so an item-detail fetch knows its owner/name and
    /// late responses for a previous repo can be ignored.
    private var currentRepo: (owner: String, name: String)?

    /// Repos (`owner/name`) whose blocked-by relationships have already been merged this session, so
    /// re-entering the "By blocked-by" grouping doesn't refetch. Cleared per repo on each item load.
    private var blockedByLoaded: Set<String> = []

    init(api: GitHubAPI, cache: GitHubCacheStore, store: Store, addComment: AddCommentUseCase) {
        self.api = api
        self.cache = cache
        self.store = store
        self.addCommentUseCase = addComment
    }

    /// Hydrate the orgs panel from the local cache (instant, no spinner), then fetch live, diff it
    /// against the cache, and update the UI only where rows actually changed. The spinner shows only
    /// when the cache is cold. Safe to call again — it cancels any in-flight load first.
    func load() {
        loadTask?.cancel()
        store.dataError = nil
        loadTask = Task { @MainActor in
            // 1) Hydrate from cache. Establish a selection only when nothing is realized yet (a fresh
            // launch), so a mid-session reload never yanks the user's current selection. `currentRepo`
            // is nil until `selectRepo` runs — true here even when a persisted key was restored but
            // not yet realized, so that key gets honored (or fallen back from) below.
            let cachedOrgs = await cache.loadOrgs()
            let cachedRepos = await cache.loadViewerRepos()
            let hadCache = !cachedOrgs.isEmpty || !cachedRepos.isEmpty
            if hadCache {
                applyOrgGroups(orgs: cachedOrgs, personalRepos: cachedRepos,
                               establishSelection: currentRepo == nil)
            } else {
                store.isLoadingOrgs = true   // cold start: this is the one spinner the user sees
            }

            // 2) Fetch live and apply the delta. Orgs and the viewer's own repos load together; the
            // personal repos surface as a synthetic group pinned at the top so a no-org account still
            // sees live data. `currentUser` scopes the cache to the signed-in login.
            do {
                async let orgsCall = api.organizations()
                async let personalCall = api.viewerRepositories()
                async let userCall = api.currentUser()
                let (orgs, personalRepos) = try await (orgsCall, personalCall)
                let viewer = try? await userCall
                if let viewer { store.currentUser = viewer }   // drives the composer avatar
                let login = viewer?.login ?? personalRepos.first?.owner

                let orgsDelta = GitHubDelta.apply(incoming: orgs, to: cachedOrgs)
                let reposDelta = GitHubDelta.apply(incoming: personalRepos, to: cachedRepos)
                if let login {
                    await cache.saveOrgs(orgsDelta.merged, viewerRepos: reposDelta.merged, login: login)
                }
                store.isLoadingOrgs = false
                // Rebuild the panel only when something changed (or it was never populated) — an
                // unchanged refresh leaves the store, the selection, and the views alone.
                if !hadCache || !orgsDelta.isUnchanged || !reposDelta.isUnchanged {
                    applyOrgGroups(orgs: orgsDelta.merged, personalRepos: reposDelta.merged,
                                   establishSelection: currentRepo == nil)
                }
            } catch {
                handle(error)
                // A cancelled load means a newer load() already owns the spinner — leave it on. On a
                // real failure the cached data (if any) stays on screen alongside the error.
                if !Task.isCancelled { store.isLoadingOrgs = false }
            }
            loadTask = nil
        }
    }

    /// Project the org groups into the store, and — when `establishSelection` — pick the repo to show.
    /// A persisted selection is honored when its repo is still available (restored on relaunch);
    /// otherwise (access lost, repo gone, or nothing saved) it falls back to expanding the first
    /// visible org and selecting its first repo. Honors the user's followed/ordered choice so a
    /// hidden org never steals focus.
    private func applyOrgGroups(orgs: [GitHubOrg], personalRepos: [GitHubRepo], establishSelection: Bool) {
        var groups = orgs.map(Org.init(domain:))
        if let personal = Org(personalRepos: personalRepos) { groups.insert(personal, at: 0) }
        store.orgs = groups
        guard establishSelection else { return }

        let availableKeys = store.visibleOrgs.flatMap { org in org.repos.map { "\($0.owner)/\($0.name)" } }
        if case .restore(let key) = RepoSelection.reconcile(persisted: store.selectedRepoKey,
                                                            available: availableKeys),
           let target = locate(repoKey: key) {
            store.expandedOrgs = [target.orgID]
            selectRepo(owner: target.owner, name: target.name)   // expands org's items, loads PRs/issues
            return
        }

        // Nothing saved, or the saved repo is gone — drop any stale key and auto-select the first repo.
        store.selectedRepoKey = nil
        guard let firstOrg = store.visibleOrgs.first else { clearItems(); return }
        store.expandedOrgs = [firstOrg.id]
        if let firstRepo = firstOrg.repos.first {
            selectRepo(owner: firstRepo.owner, name: firstRepo.name)
        } else {
            clearItems()
        }
    }

    /// Find the visible org holding `repoKey` (`owner/name`), returning its id plus the repo's
    /// owner/name. Only repos in `visibleOrgs` are reachable, so a key in a hidden/removed org
    /// resolves to nil and the caller falls back to auto-selection.
    private func locate(repoKey: String) -> (orgID: String, owner: String, name: String)? {
        for org in store.visibleOrgs {
            if let repo = org.repos.first(where: { "\($0.owner)/\($0.name)" == repoKey }) {
                return (org.id, repo.owner, repo.name)
            }
        }
        return nil
    }

    /// Switch the active repo: update the breadcrumb/header and reload its PRs and issues.
    func selectRepo(owner: String, name: String) {
        currentRepo = (owner, name)
        store.selectedRepoKey = "\(owner)/\(name)"
        store.collapsedItems = []   // a collapsed number from the old repo would hide an unrelated item
        loadItems(owner: owner, name: name)
    }

    /// Lazily fetch GitHub issue dependencies and mark blocked items — but only while the user is in
    /// the "By blocked-by" grouping, since it costs one REST call per item. Idempotent per repo for
    /// the session (the flag is cleared on each item load, so a refresh re-fetches). Wired to the
    /// View's group-mode change and re-run after items land so entering a repo already in that mode
    /// populates. A no-op in any other grouping.
    func loadBlockedByIfNeeded() {
        guard store.groupBy == .blocked, let repo = currentRepo else { return }
        let repoKey = "\(repo.owner)/\(repo.name)"
        guard !blockedByLoaded.contains(repoKey) else { return }
        blockedByLoaded.insert(repoKey)
        let api = self.api
        let (owner, name) = (repo.owner, repo.name)
        Task { @MainActor in
            @MainActor func isCurrent() -> Bool { currentRepo?.owner == owner && currentRepo?.name == name }
            let numbers = (store.issues + store.prs).compactMap { Int($0.id) }
            guard !numbers.isEmpty else { return }
            let blockers = await Self.fetchBlockers(api: api, owner: owner, name: name, numbers: numbers)
            guard isCurrent() else { return }
            store.prs = store.prs.map { Self.applyBlocked(blockers, to: $0) }
            store.issues = store.issues.map { Self.applyBlocked(blockers, to: $0) }
        }
    }

    /// Fetch each item's blockers concurrently, bounded so a big repo doesn't open dozens of
    /// sockets at once. A per-item failure (e.g. the feature isn't enabled) counts as no blockers.
    private static func fetchBlockers(api: GitHubAPI, owner: String, name: String,
                                      numbers: [Int]) async -> [Int: [Int]] {
        let maxConcurrent = 8
        var iterator = numbers.makeIterator()
        return await withTaskGroup(of: (Int, [Int]).self) { group in
            func addNext() {
                guard let number = iterator.next() else { return }
                group.addTask {
                    let deps = (try? await api.issueDependencies(
                        owner: owner, repo: name, number: number)) ?? []
                    return (number, deps)
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            var result: [Int: [Int]] = [:]
            for await (number, deps) in group {
                result[number] = deps
                addNext()
            }
            return result
        }
    }

    /// Set the item's first blocker (so the grouped list nests it and shows the ⊘ badge), or leave
    /// it untouched when it has none.
    private static func applyBlocked(_ blockers: [Int: [Int]], to item: Item) -> Item {
        guard let number = Int(item.id), let first = blockers[number]?.first else { return item }
        var copy = item
        copy.blocked = String(first)
        return copy
    }

    /// Re-run the current repo's item fetch after the status filter changed — the new selection is
    /// both the display filter and the fetch scope, so widening it pulls in the newly-shown states
    /// (and narrowing it prunes them from the cache). The display already updated instantly off the
    /// cache; this reconciles the cache with the new scope. A no-op before a repo is selected.
    func reloadCurrentItems() {
        guard let repo = currentRepo else { return }
        loadItems(owner: repo.owner, name: repo.name)
    }

    /// User-initiated global refresh: reload the orgs/repos panel and the current repo's PRs/issues at
    /// once. Tracked by `store.isRefreshing` so the orgs panel shows a spinner and ignores repeat
    /// clicks until both fetches settle. Each sub-load stays hydrate-then-delta, so unchanged data
    /// leaves the views untouched.
    func refresh() {
        guard !store.isRefreshing else { return }   // debounce: one global refresh at a time
        store.isRefreshing = true
        load()                 // sets loadTask
        reloadCurrentItems()   // sets itemsTask (a no-op leaving it nil when no repo is selected)
        // Safe to read the handles now: this runs on @MainActor and hasn't awaited, so the freshly
        // created @MainActor sub-tasks can't have started or cleared themselves yet.
        let orgsLoad = loadTask
        let itemsLoad = itemsTask
        Task { @MainActor in
            await orgsLoad?.value     // a cancelled Task<Void, Never> still completes here
            await itemsLoad?.value
            store.isRefreshing = false
        }
    }

    /// Select a list item: show its lead content immediately (the store already has it) and
    /// fetch the hydrated detail (body tasks, comments, PR checks) to upgrade it.
    func selectItem(number: Int) {
        guard let repo = currentRepo else { return }
        store.selectedItemId = String(number)
        store.selectedItemDetail = nil
        loadDetail(owner: repo.owner, name: repo.name, number: number)
    }

    /// Post a comment on the open item and, on success, append the comment GitHub stored to the
    /// detail in place (no re-fetch) so it shows immediately, authored by the viewer. `completion`
    /// runs on the main actor: `(true, nil)` clears the composer; `(false, message)` keeps the
    /// user's draft and surfaces `message`. A blank body is reported as `(false, nil)` (no message —
    /// the view just doesn't send). Mirrors the read path's task ownership: a comment that lands
    /// after the user moved on isn't grafted onto a different item.
    func submitComment(body: String, completion: @escaping (Bool, String?) -> Void) {
        guard let repo = currentRepo, let number = Int(store.selectedItemId) else {
            completion(false, nil); return
        }
        Task { @MainActor in
            do {
                let comment = try await addCommentUseCase(
                    owner: repo.owner, repo: repo.name, number: number, body: body)
                if store.selectedItemId == String(number), var detail = store.selectedItemDetail {
                    detail.comments.append(Comment(domain: comment))
                    store.selectedItemDetail = detail
                }
                completion(true, nil)
            } catch AddCommentError.empty {
                completion(false, nil)
            } catch {
                completion(false, Self.message(for: error))
            }
        }
    }

    /// Drop all live data on sign-out so the UI returns to an empty, signed-out shell.
    func clear() {
        loadTask?.cancel(); itemsTask?.cancel(); detailTask?.cancel()
        currentRepo = nil
        blockedByLoaded = []
        store.collapsedItems = []
        store.currentUser = nil
        store.orgs = []
        store.expandedOrgs = []
        store.selectedRepoKey = nil
        clearItems()
        store.dataError = nil
        // Cancelled tasks won't reach their ownership-guarded clears, so reset here.
        store.isLoadingOrgs = false
        store.isLoadingItems = false
        store.isLoadingDetail = false
        store.isRefreshing = false
        store.prsTruncated = false
        store.issuesTruncated = false
        // Drop the on-disk cache too, so the next user to sign in never sees this account's data.
        Task { await cache.clear() }
    }

    // MARK: - Private

    /// Hydrate this repo's PRs/issues from the cache (instant, no spinner), then fetch live, diff
    /// against the cache, and update only the lists that changed. The spinner shows only when the
    /// repo has nothing cached.
    private func loadItems(owner: String, name: String) {
        itemsTask?.cancel()
        detailTask?.cancel()
        store.dataError = nil
        let repoKey = "\(owner)/\(name)"
        blockedByLoaded.remove(repoKey)   // a fresh load re-fetches blockers if "By blocked-by" is on
        itemsTask = Task { @MainActor in
            // Only the task whose repo is still the current one owns the spinner and the store: a
            // stale/cancelled response for a superseded repo must not stomp the newer fetch.
            @MainActor func isCurrent() -> Bool { currentRepo?.owner == owner && currentRepo?.name == name }

            let cachedPRs = await cache.loadItems(repoKey: repoKey, kind: .pullRequest)
            let cachedIssues = await cache.loadItems(repoKey: repoKey, kind: .issue)
            guard isCurrent() else { return }
            let hadCache = !cachedPRs.isEmpty || !cachedIssues.isEmpty
            if hadCache {
                store.prs = cachedPRs.map(Item.init(domain:))
                store.issues = cachedIssues.map(Item.init(domain:))
                reconcileSelection(owner: owner, name: name)
            } else {
                store.isLoadingItems = true
            }

            do {
                // Fetch each list in the user's selected states. Open-only is the cheap default;
                // a broader selection bounds closed/merged history and reports the cap.
                async let prs = api.items(owner: owner, repo: name, kind: .pullRequest,
                                          states: store.prStates)
                async let issues = api.items(owner: owner, repo: name, kind: .issue,
                                             states: store.issueStates)
                let (prResult, issueResult) = try await (prs, issues)
                // Ignore a response that landed after the user switched repos.
                guard isCurrent() else { return }
                let prDelta = GitHubDelta.apply(incoming: prResult.items, to: cachedPRs)
                let issueDelta = GitHubDelta.apply(incoming: issueResult.items, to: cachedIssues)
                await cache.saveItems(prDelta.merged, repoKey: repoKey, kind: .pullRequest)
                await cache.saveItems(issueDelta.merged, repoKey: repoKey, kind: .issue)
                guard isCurrent() else { return }
                store.isLoadingItems = false
                store.prsTruncated = prResult.reachedHistoryCap
                store.issuesTruncated = issueResult.reachedHistoryCap
                if !hadCache || !prDelta.isUnchanged { store.prs = prDelta.merged.map(Item.init(domain:)) }
                if !hadCache || !issueDelta.isUnchanged { store.issues = issueDelta.merged.map(Item.init(domain:)) }
                if !hadCache || !prDelta.isUnchanged || !issueDelta.isUnchanged {
                    reconcileSelection(owner: owner, name: name)
                }
                loadBlockedByIfNeeded()   // populate the ⊘ tree when this repo opens already in that mode
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
        // Keep the open item visible: if it lives in the other tab — e.g. an issue restored from a
        // previous session while the tab defaulted to PRs — switch to that tab so the list shows it.
        // Mid-session this is a no-op, since the open item is always in the current tab.
        if !store.listItems.contains(where: { $0.id == store.selectedItemId }) {
            if store.prs.contains(where: { $0.id == store.selectedItemId }) { store.tab = .prs }
            else if store.issues.contains(where: { $0.id == store.selectedItemId }) { store.tab = .issues }
        }
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
