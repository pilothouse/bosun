import Application
import Domain
import Foundation
import os

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
    /// The write seams. The controller drives them like every other use case; the view never
    /// touches the client directly. `addComment` posts a comment; `mergePullRequest` merges a PR;
    /// `editItem` edits an issue/PR's title/body/labels/assignees.
    private let addCommentUseCase: AddCommentUseCase
    private let mergePullRequestUseCase: MergePullRequestUseCase
    private let closePullRequestUseCase: ClosePullRequestUseCase
    private let closeIssueUseCase: CloseIssueUseCase
    private let editItemUseCase: EditItemUseCase
    private let manageReviewersUseCase: ManageReviewersUseCase

    /// The current repo's label palette and assignable users, cached per repo so re-opening a picker
    /// doesn't refetch (mirrors `blockedByLoaded`'s per-scope memo). Keyed by `owner/name`; cleared on
    /// a repo/item-scope change in `loadItems`/`loadOrgItems`. Reads have no business rule, so they're
    /// fetched straight through `api` (like `itemDetail`), not behind a use case.
    private var editChoicesCache: [String: ([LabelChoice], [Assignee])] = [:]

    private var loadTask: Task<Void, Never>?
    private var itemsTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    /// Fired when repeated 401s confirm the stored token is revoked. The App layer wires this to the
    /// auth controller's session-expiry recovery (sign out + reopen the device flow). Explicit hook
    /// (vs. the controller reaching into auth) mirrors `GitHubAuthController`'s `onSignedIn`/`onSignedOut`.
    var onUnauthorized: (() -> Void)?

    /// Consecutive `unauthorized` responses with no success between them — the first is retried, the
    /// second re-authenticates (see `SessionExpiryPolicy`). Reset by any successful fetch.
    private var consecutiveUnauthorized = 0
    /// True from the moment a recovery is fired until the next successful authenticated call. While
    /// set, a fresh 401 surfaces an error instead of re-recovering — this is what bounds a sign-out
    /// loop if the replacement token is also bad. Deliberately NOT cleared by `clear()` (which runs
    /// *during* recovery via `onSignedOut`); only a real success clears it.
    private var awaitingRevalidation = false

    /// The repo whose items are currently shown, so late responses for a previous repo can be
    /// ignored. nil in org-aggregate scope (see `currentOrg`); item-detail fetches route by the
    /// item's own repo, not this, so a cross-repo aggregate list still opens details correctly.
    private var currentRepo: (owner: String, name: String)?

    /// The org whose aggregated items (every repo's PRs/issues) are currently shown, or nil in
    /// single-repo scope. Exactly one of `currentRepo`/`currentOrg` is set — they're the two
    /// mutually-exclusive selection scopes (see `RepoSelection`). Used so a stale org fetch is
    /// dropped when the scope moves on, mirroring `currentRepo`.
    private var currentOrg: String?

    /// Repos (`owner/name`) whose blocked-by relationships have already been merged this session, so
    /// re-entering the "By blocked-by" grouping doesn't refetch. Cleared per repo on each item load.
    private var blockedByLoaded: Set<String> = []

    init(api: GitHubAPI, cache: GitHubCacheStore, store: Store, addComment: AddCommentUseCase,
         mergePullRequest: MergePullRequestUseCase, closePullRequest: ClosePullRequestUseCase,
         closeIssue: CloseIssueUseCase, editItem: EditItemUseCase,
         manageReviewers: ManageReviewersUseCase) {
        self.api = api
        self.cache = cache
        self.store = store
        self.addCommentUseCase = addComment
        self.mergePullRequestUseCase = mergePullRequest
        self.closePullRequestUseCase = closePullRequest
        self.closeIssueUseCase = closeIssue
        self.editItemUseCase = editItem
        self.manageReviewersUseCase = manageReviewers
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
                               establishSelection: currentRepo == nil && currentOrg == nil)
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
                sessionValidated()   // a successful authenticated call clears any 401 streak/recovery
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
                                   establishSelection: currentRepo == nil && currentOrg == nil)
                }
            } catch {
                handleFetchError(error) { [weak self] in self?.load() }
                // A cancelled load means a newer load() already owns the spinner — leave it on. On a
                // real failure the cached data (if any) stays on screen alongside the error.
                if !Task.isCancelled { store.isLoadingOrgs = false }
            }
            loadTask = nil
        }
    }

    /// Measurement-only seam (`BOSUN_PERF_SEED`, wired in `AppDelegate`): hydrate the orgs/repos tree
    /// and the first repo's PRs/issues straight from the on-disk cache with **no** live fetch, so a
    /// seeded heavy cache stays resident long enough to sample peak memory. The first `loadOrgs` read
    /// pulls the whole snapshot (orgs + the full `items` dict) into the cache's in-memory mirror —
    /// the dominant resident cost we want to measure. Reuses the same `applyOrgGroups` /
    /// `Item.init(domain:)` projection as the live path; never called in normal use.
    func loadFromCacheForPerf() {
        Task { @MainActor in
            let cachedOrgs = await cache.loadOrgs()
            let cachedRepos = await cache.loadViewerRepos()
            applyOrgGroups(orgs: cachedOrgs, personalRepos: cachedRepos, establishSelection: false)
            guard let firstOrg = store.orgs.first, let firstRepo = firstOrg.repos.first else { return }
            store.expandedOrgs = [firstOrg.id]
            let repoKey = "\(firstRepo.owner)/\(firstRepo.name)"
            store.selectedRepoKey = repoKey
            store.prs = (await cache.loadItems(repoKey: repoKey, kind: .pullRequest)).map(Item.init(domain:))
            store.issues = (await cache.loadItems(repoKey: repoKey, kind: .issue)).map(Item.init(domain:))
        }
    }

    /// Project the org groups into the store, and — when `establishSelection` — pick the repo to show.
    /// A persisted selection is honored when its repo is still available (restored on relaunch);
    /// otherwise (access lost, repo gone, or nothing saved) it falls back to expanding the first
    /// visible org and selecting its first repo. Honors the user's followed/ordered choice so a
    /// hidden org never steals focus.
    private func applyOrgGroups(orgs: [GitHubOrg], personalRepos: [GitHubRepo], establishSelection: Bool) {
        var groups = orgs.map(Org.init(domain:))
        if let personal = Org(personalRepos: personalRepos, viewer: store.currentUser) {
            groups.insert(personal, at: 0)
        }
        store.orgs = groups
        guard establishSelection else { return }

        // Restore a remembered aggregate-org scope first (org and repo selection are mutually
        // exclusive). loadOrgItems reconciles the remembered open item against the aggregate, so the
        // org, its sections, and the open issue all come back together. The "All organizations"
        // sentinel isn't in `visibleOrgs`, so it's restorable whenever any org is visible to union.
        let orgScopeRestorable = store.selectedOrgId == Org.allOrgsID
            ? !store.visibleOrgs.isEmpty
            : store.visibleOrgs.contains(where: { $0.id == store.selectedOrgId })
        if !store.selectedOrgId.isEmpty, orgScopeRestorable {
            selectOrg(id: store.selectedOrgId)
            return
        }
        store.selectedOrgId = ""   // a saved org that's no longer visible — drop it, fall back to repo

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
        currentOrg = nil
        // Org and repo selection are mutually exclusive — picking a repo clears any org highlight.
        let sel = RepoSelection.selectingRepo("\(owner)/\(name)")
        store.selectedOrgId = sel.orgId
        store.selectedRepoKey = sel.repoKey
        store.collapsedItems = []   // a collapsed number from the old repo would hide an unrelated item
        loadItems(owner: owner, name: name)
    }

    /// Switch the active scope to a whole org: aggregate the open PRs/issues across every repo the
    /// org holds, shown as per-repo sections. Mutually exclusive with `selectRepo` — picking an org
    /// clears any repo highlight (and vice-versa). The org-row click in the panel drives this.
    func selectOrg(id: String) {
        currentOrg = id
        currentRepo = nil
        let sel = RepoSelection.selectingOrg(id)
        store.selectedOrgId = sel.orgId
        store.selectedRepoKey = sel.repoKey
        store.expandedOrgs.insert(id)   // selecting an org expands its repo list in the panel
        store.collapsedItems = []       // section-collapse state is fresh for the new scope
        loadOrgItems(orgId: id)
    }

    /// Lazily fetch GitHub issue dependencies and mark blocked items — but only while the user is in
    /// the "By blocked-by" grouping, since it costs one REST call per item. Works for a single repo
    /// and for the aggregate org view: items can span repos, so blockers are fetched per repo and
    /// keyed by each item's composite id (`repo#number`) to avoid same-number collisions across repos.
    /// Idempotent per scope for the session (the flag is cleared on each item load, so a refresh
    /// re-fetches). Wired to the View's group-mode change and re-run after items land so entering a
    /// scope already in that mode populates. A no-op in any other grouping.
    func loadBlockedByIfNeeded() {
        guard store.groupBy == .blocked else { return }
        let scopeKey: String
        if let repo = currentRepo { scopeKey = "\(repo.owner)/\(repo.name)" }
        else if let org = currentOrg { scopeKey = "org:\(org)" }
        else { return }
        guard !blockedByLoaded.contains(scopeKey) else { return }
        blockedByLoaded.insert(scopeKey)
        let api = self.api
        let (scopeRepo, scopeOrg) = (currentRepo, currentOrg)
        Task { @MainActor in
            @MainActor func isCurrent() -> Bool {
                currentRepo?.owner == scopeRepo?.owner && currentRepo?.name == scopeRepo?.name
                    && currentOrg == scopeOrg
            }
            // Dependencies are same-repo, so group the (possibly multi-repo) items by repo, fetch
            // each repo's blockers, and key them by composite id so two repos' #N can't collide.
            let byRepo = Dictionary(grouping: store.issues + store.prs, by: \.repo)
            guard !byRepo.isEmpty else { return }
            var blockers: [String: [Int]] = [:]
            for (repoKey, repoItems) in byRepo {
                let parts = repoKey.split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let perRepo = await Self.fetchBlockers(
                    api: api, owner: String(parts[0]), name: String(parts[1]),
                    numbers: repoItems.map(\.number))
                for (num, deps) in perRepo where !deps.isEmpty { blockers["\(repoKey)#\(num)"] = deps }
            }
            guard isCurrent() else { return }
            store.prs = store.prs.map { Self.applyBlocked(blockers, to: $0) }
            store.issues = store.issues.map { Self.applyBlocked(blockers, to: $0) }
            // The open detail is a separate copy that outranks the list item in `selectedItem`, so
            // refresh its blocked marker too. Without this, a detail built before enrichment landed —
            // e.g. the restored selection on relaunch, whose detail loads first — keeps an empty
            // marker until the item is re-opened.
            if let detail = store.selectedItemDetail {
                let updated = Self.applyBlocked(blockers, to: detail)
                if updated.blocked != detail.blocked { store.selectedItemDetail = updated }
            }
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
    /// it untouched when it has none. Keyed by the item's composite id (`repo#number`) so the org
    /// view, whose items span repos, can't cross-apply one repo's blockers to another's same number.
    private static func applyBlocked(_ blockers: [String: [Int]], to item: Item) -> Item {
        guard let first = blockers[item.id]?.first else { return item }
        var copy = item
        copy.blocked = String(first)
        return copy
    }

    /// Re-run the current repo's item fetch after the status filter changed — the new selection is
    /// both the display filter and the fetch scope, so widening it pulls in the newly-shown states
    /// (and narrowing it prunes them from the cache). The display already updated instantly off the
    /// cache; this reconciles the cache with the new scope. A no-op before a repo is selected.
    func reloadCurrentItems() {
        // A filter change must not move the user off the tab they're on, so preserve it across the
        // reload (the selection-follows-tab switch in `reconcileSelectionForScope` is for
        // launch/restore only). Routes to whichever scope is active.
        if let org = currentOrg {
            loadOrgItems(orgId: org, preserveTab: true)
        } else if let repo = currentRepo {
            loadItems(owner: repo.owner, name: repo.name, preserveTab: true)
        }
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

    /// Re-fetch just the accessible organization *set* (and the viewer's repos) with the current
    /// token and re-project the panel — leaving the open item/repo selection alone, since `load()`
    /// only re-establishes a selection on a cold start. Surfaced by the Manage sheet's "Sync
    /// organizations" so a newly-granted org appears (or a revoked one disappears) without a restart
    /// (#81). Narrower than `refresh()` — it skips the current repo's items — but shares the
    /// `isRefreshing` debounce + spinner.
    func syncOrgs() {
        guard !store.isRefreshing else { return }
        store.isRefreshing = true
        load()                 // sets loadTask; re-fetches api.organizations() and applies the delta
        let orgsLoad = loadTask
        Task { @MainActor in
            await orgsLoad?.value
            store.isRefreshing = false
        }
    }

    /// Background auto-refresh (#97): refresh exactly one scoped unit and await it, hydrate-then-delta
    /// like every other fetch. `.currentItems` routes through `reloadCurrentItems()` (preserveTab: true),
    /// so a background update never triggers the selection-follows-tab switch (#100). Awaitable so the
    /// scheduler serializes ticks and never overlaps fetches; reading the task handle right after the
    /// call is safe (same `@MainActor`, no `await` between — mirrors `refresh()`).
    func backgroundRefresh(_ unit: RefreshPlanner.Unit) async {
        switch unit {
        case .orgList:
            load()
            await loadTask?.value
        case .currentItems:
            reloadCurrentItems()
            await itemsTask?.value
        }
    }

    /// Select a list item: show its lead content immediately (the store already has it) and
    /// fetch the hydrated detail (body tasks, comments, PR checks) to upgrade it. Re-clicking the
    /// already-open item is a no-op (`DetailReselectionPolicy`) — no flash, no refetch, scroll kept.
    /// The compare is against the *loaded* detail's id, not `selectedItemId`, because the panel sets
    /// `selectedItemId` before calling here, so a genuine new selection still arrives with the prior
    /// item's detail loaded — and a re-click after a failed/aborted fetch (no loaded detail) retries.
    func selectItem(_ item: Item) {
        guard DetailReselectionPolicy.shouldFetchDetail(
            loadedDetailId: store.selectedItemDetail?.id, target: item.id) else { return }
        store.selectedItemId = item.id
        store.selectedItemDetail = nil
        loadDetail(for: item)
    }

    /// Force-reload the open item's detail, bypassing the reselection skip. Drops the hydrated detail
    /// to re-show the "Loading details…" placeholder, then re-fetches. Wired to the detail pane's
    /// in-pane Refresh button. `selectedItem` is the hydrated item while one is loaded, so this routes
    /// the fetch to the item's own repo (correct in aggregate-org scope).
    func refreshDetail() {
        guard let item = store.selectedItem else { return }
        store.selectedItemDetail = nil
        loadDetail(for: item)
    }

    /// Post a comment on the open item and, on success, append the comment GitHub stored to the
    /// detail in place (no re-fetch) so it shows immediately, authored by the viewer. `completion`
    /// runs on the main actor: `(true, nil)` clears the composer; `(false, message)` keeps the
    /// user's draft and surfaces `message`. A blank body is reported as `(false, nil)` (no message —
    /// the view just doesn't send). Mirrors the read path's task ownership: a comment that lands
    /// after the user moved on isn't grafted onto a different item.
    func submitComment(body: String, completion: @escaping (Bool, String?) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion(false, nil); return
        }
        let number = item.number
        Task { @MainActor in
            do {
                let comment = try await addCommentUseCase(
                    owner: repo.owner, repo: repo.name, number: number, body: body)
                if store.selectedItemId == selectedId, var detail = store.selectedItemDetail {
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

    /// Merge the open PR with the chosen `merge` request and, on success, re-hydrate the item so the
    /// detail pane reflects `merged` (the type badge flips and `PRMergePolicy` then hides the
    /// control). `completion` runs on the main actor: `(true, nil)` clears the form, `(false,
    /// message)` keeps the user's edits and surfaces `message`. Mirrors `submitComment`'s ownership:
    /// a merge that lands after the user moved on doesn't refresh a different item.
    func mergePullRequest(_ merge: PRMergeRequest, completion: @escaping (Bool, String?) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion(false, nil); return
        }
        let number = item.number
        Task { @MainActor in
            do {
                _ = try await mergePullRequestUseCase(
                    owner: repo.owner, repo: repo.name, number: number, merge: merge)
                completion(true, nil)
                // Reflect the new state on the list row so the active status filter re-checks it — a
                // merged PR drops out of an open-only list at once (issue's blocked-by tree re-roots
                // any items it blocked). The detail re-fetch below repaints the pane as merged.
                applyResolvedState(.merged, toItemId: selectedId)
                // Re-fetch only if the user is still on this item; the detail now reports `merged`.
                if store.selectedItemId == selectedId { refreshDetail() }
            } catch {
                completion(false, Self.mergeMessage(for: error))
            }
        }
    }

    /// Close the open PR without merging and, if `deleteBranch`, remove its head branch. Mirrors
    /// `mergePullRequest`: resolve the selected item, perform the write behind the port, and on success
    /// re-fetch (the PR now reports `closed`, so the close control hides itself via `PRClosePolicy`).
    /// A close failure keeps the pane's form open with a reason. If the PR closed but the branch delete
    /// failed, the close still counts as success — the leftover-branch reason is surfaced as a
    /// non-blocking banner (`store.dataError`), not treated as a failed close.
    func closePullRequest(deleteBranch: Bool, completion: @escaping (Bool, String?) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion(false, nil); return
        }
        let number = item.number
        let branch = item.branch
        Task { @MainActor in
            do {
                let result = try await closePullRequestUseCase(
                    owner: repo.owner, repo: repo.name, number: number,
                    branch: branch, deleteBranch: deleteBranch)
                if case let .failed(reason) = result.branchDeletion {
                    store.dataError = "Closed #\(number), but couldn't delete branch "
                        + "\(branch ?? ""): \(reason)."
                }
                completion(true, nil)
                // Reflect the new state on the list row so the active status filter re-checks it — a
                // closed PR drops out of an open-only list at once.
                applyResolvedState(.closed, toItemId: selectedId)
                // Re-fetch only if the user is still on this item; the detail now reports `closed`.
                if store.selectedItemId == selectedId { refreshDetail() }
            } catch {
                completion(false, Self.closeMessage(for: error))
            }
        }
    }

    /// Close an open issue with a reason. Mirrors `closePullRequest` but without branch deletion.
    /// `duplicateOf` (the parent issue number) is threaded to the use case so a "close as duplicate"
    /// posts the `Duplicate of #N` marker comment before closing. Re-fetches the detail on success so
    /// the close button disappears (issue now reports `closed`).
    func closeIssue(reason: IssueCloseReason, duplicateOf: Int?,
                    completion: @escaping (Bool, String?) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion(false, nil); return
        }
        Task { @MainActor in
            do {
                _ = try await closeIssueUseCase(
                    owner: repo.owner, repo: repo.name,
                    number: item.number, reason: reason, duplicateOf: duplicateOf)
                completion(true, nil)
                // Reflect the new state on the list row so the active status filter re-checks it — a
                // closed issue drops out of an open-only list at once (a blocker issue's tree
                // re-roots the items it blocked, via `GitHubItemTree`).
                applyResolvedState(.closed, toItemId: selectedId)
                if store.selectedItemId == selectedId { refreshDetail() }
            } catch {
                completion(false, Self.closeIssueMessage(for: error))
            }
        }
    }

    /// Apply a just-committed terminal state (merge/close) to the item's list row in place, so the
    /// active status filter re-evaluates it immediately — a merged/closed row leaves an open-only
    /// list without waiting for the next re-fetch. Runs unconditionally (not gated on the item still
    /// being selected): the row should update even if the user moved to another item in this scope;
    /// a scope switch clears the lists, so the id simply isn't found and this is a no-op. The
    /// blocked-by tree needs no special handling — `GitHubItemTree` re-roots any items the removed
    /// row blocked rather than dropping them.
    private func applyResolvedState(_ state: GitHubItemState, toItemId id: String) {
        if let i = store.prs.firstIndex(where: { $0.id == id }) { store.prs[i].applyResolved(state: state) }
        if let i = store.issues.firstIndex(where: { $0.id == id }) { store.issues[i].applyResolved(state: state) }
    }

    /// Search the open item's repo for issues matching `query`, projected to presentation `Item`s for
    /// the "close as duplicate" parent picker. Mirrors `loadEditChoices`: routes to the item's own repo
    /// (correct in aggregate-org scope), drops the item itself from the results, and reports on the main
    /// actor only while it's still selected. A blank query returns nothing without a round-trip; a
    /// failed search yields an empty list (the picker just shows "no matches").
    func searchIssues(query: String, completion: @escaping ([Item]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedId = store.selectedItemId
        guard !trimmed.isEmpty,
              let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion([]); return
        }
        Task { @MainActor in
            let found = (try? await api.searchIssues(owner: repo.owner, repo: repo.name, query: trimmed)) ?? []
            let results = found.map(Item.init(domain:)).filter { $0.number != item.number }
            if store.selectedItemId == selectedId { completion(results) }
        }
    }

    /// Close failures need their own wording for the codes the generic `message(for:)` would flatten to
    /// "check your connection": a 403 is a permission denial (the token can't write this repo). A merge
    /// isn't in play here, so there's no 405/409 nuance — everything else defers to `message(for:)`.
    private static func closeMessage(for error: Error) -> String {
        switch error as? GitHubAPIError {
        case .http(403):
            return "You don't have permission to close this pull request."
        default:
            return message(for: error)
        }
    }

    private static func closeIssueMessage(for error: Error) -> String {
        switch error as? GitHubAPIError {
        case .http(403):
            return "You don't have permission to close this issue."
        default:
            return message(for: error)
        }
    }

    /// Edit the open item's title/body/labels/assignees and, on success, apply GitHub's stored copy in
    /// place to both the open detail *and* its list row — no re-fetch, so there's no loading flash and
    /// the response's canonical label colors / assignee avatars are used (the PR-only detail fields the
    /// PATCH response omits — checks/files/mergeability — are preserved, since `applyEdited` layers the
    /// edit onto the existing item rather than replacing it). `completion` runs on the main actor:
    /// `(true, nil)` succeeded; `(false, message)` keeps the user's edits and surfaces `message`; a
    /// no-op/blank-title edit is reported as `(false, message)` from the use case's rule. Mirrors
    /// `submitComment`'s ownership: an edit that lands after the user moved on isn't grafted onto a
    /// different item.
    func editItem(_ edit: GitHubItemEdit, completion: @escaping (Bool, String?) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion(false, nil); return
        }
        let number = item.number
        Task { @MainActor in
            do {
                let updated = try await editItemUseCase(
                    owner: repo.owner, repo: repo.name, number: number, edit: edit)
                // Apply only if the user is still on this item (a late edit must not stomp another).
                if store.selectedItemId == selectedId {
                    applyEdited(updated, toItemId: selectedId)
                }
                completion(true, nil)
            } catch EditItemError.noChanges {
                completion(false, nil)
            } catch EditItemError.emptyTitle {
                completion(false, "A title is required.")
            } catch {
                completion(false, Self.editMessage(for: error))
            }
        }
    }

    /// Layer GitHub's stored edit onto the matching list row and the open detail, leaving each item's
    /// detail-only collections (comments/checks/files) and PR fields intact (see `Item.applyEdited`).
    private func applyEdited(_ updated: Domain.GitHubItem, toItemId id: String) {
        if let i = store.prs.firstIndex(where: { $0.id == id }) { store.prs[i].applyEdited(from: updated) }
        if let i = store.issues.firstIndex(where: { $0.id == id }) { store.issues[i].applyEdited(from: updated) }
        if var detail = store.selectedItemDetail, detail.id == id {
            detail.applyEdited(from: updated)
            store.selectedItemDetail = detail
        }
    }

    /// Request a reviewer or cancel a pending request on the open PR (issue #70), updating the open
    /// detail's reviewers in place. The change applies optimistically (the chip/badge updates at
    /// once), then reconciles with GitHub's authoritative pending set on success, or reverts on
    /// failure. `completion` runs on the main actor: `(true, nil)` applied; `(false, message)`
    /// reverted. Mirrors `editItem`'s ownership — a write that lands after the user moved on isn't
    /// grafted onto a different item.
    func manageReviewers(_ action: ReviewerAction, logins: [String],
                         completion: @escaping (Bool, String?) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion(false, nil); return
        }
        let number = item.number
        // Optimistic update of the open detail, captured for revert on failure.
        let prior = store.selectedItemDetail?.reviewers
        if var detail = store.selectedItemDetail, detail.id == selectedId {
            detail.reviewers = Self.optimisticReviewers(detail.reviewers, action: action, logins: logins)
            store.selectedItemDetail = detail
        }
        Task { @MainActor in
            do {
                let pending: [Domain.GitHubReviewer]
                switch action {
                case .request:
                    pending = try await manageReviewersUseCase.request(
                        owner: repo.owner, repo: repo.name, number: number, logins: logins)
                case .remove:
                    pending = try await manageReviewersUseCase.remove(
                        owner: repo.owner, repo: repo.name, number: number, logins: logins)
                }
                // Reconcile with GitHub's authoritative pending set (keep submitted reviews, replace
                // the pending ones) — only if the user is still on this item.
                if store.selectedItemId == selectedId, var detail = store.selectedItemDetail,
                   detail.id == selectedId {
                    detail.reviewers = detail.reviewers.filter { !$0.isPending } + pending.map(Reviewer.init(domain:))
                    store.selectedItemDetail = detail
                }
                completion(true, nil)
            } catch {
                if store.selectedItemId == selectedId, let prior,
                   var detail = store.selectedItemDetail, detail.id == selectedId {
                    detail.reviewers = prior   // undo the optimistic change
                    store.selectedItemDetail = detail
                }
                completion(false, Self.reviewerMessage(for: error))
            }
        }
    }

    /// Apply a request/remove to the reviewer list optimistically. A request flips the login to a
    /// fresh `.pending` chip (the avatar fills in once GitHub responds); a remove drops the matching
    /// pending chip. Submitted reviews are untouched.
    private static func optimisticReviewers(_ current: [Reviewer], action: ReviewerAction,
                                            logins: [String]) -> [Reviewer] {
        var result = current
        switch action {
        case .request:
            for login in logins {
                result.removeAll { $0.login == login }
                result.append(Reviewer(domain: GitHubReviewer(login: login, state: .pending)))
            }
        case .remove:
            result.removeAll { logins.contains($0.login) && $0.isPending }
        }
        return result
    }

    /// Fetch the open item's repo label palette and assignable users for the edit pane's pickers,
    /// projected to presentation choices. Cached per repo for the session so re-opening a picker is
    /// instant; an empty result (or failure) just yields empty pickers. Routes to the item's own repo
    /// (correct in aggregate-org scope), and reports on the main actor only while it's still selected.
    func loadEditChoices(completion: @escaping ([LabelChoice], [Assignee]) -> Void) {
        let selectedId = store.selectedItemId
        guard let item = (store.prs + store.issues).first(where: { $0.id == selectedId }),
              let repo = item.ownerRepo else {
            completion([], []); return
        }
        let key = "\(repo.owner)/\(repo.name)"
        if let cached = editChoicesCache[key] { completion(cached.0, cached.1); return }
        Task { @MainActor in
            async let labelsCall = api.repositoryLabels(owner: repo.owner, repo: repo.name)
            async let usersCall = api.assignableUsers(owner: repo.owner, repo: repo.name)
            let labels = (try? await labelsCall) ?? []
            let users = (try? await usersCall) ?? []
            let choices = (labels.map(LabelChoice.init(domain:)), users.map(Assignee.init(domain:)))
            editChoicesCache[key] = choices
            if store.selectedItemId == selectedId { completion(choices.0, choices.1) }
        }
    }

    /// Drop all live data on sign-out so the UI returns to an empty, signed-out shell.
    func clear() {
        loadTask?.cancel(); itemsTask?.cancel(); detailTask?.cancel()
        currentRepo = nil
        currentOrg = nil
        blockedByLoaded = []
        editChoicesCache = [:]
        consecutiveUnauthorized = 0   // a fresh streak starts next session; `awaitingRevalidation`
                                      // intentionally survives (clear() runs during recovery itself)
        store.collapsedItems = []
        store.currentUser = nil
        store.orgs = []
        store.expandedOrgs = []
        store.selectedRepoKey = nil
        store.selectedOrgId = ""
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
    private func loadItems(owner: String, name: String, preserveTab: Bool = false) {
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
                reconcileSelectionForScope(establishing: !preserveTab)
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
                sessionValidated()   // a successful authenticated call clears any 401 streak/recovery
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
                    reconcileSelectionForScope(establishing: !preserveTab && !hadCache)
                }
                loadBlockedByIfNeeded()   // populate the ⊘ tree when this repo opens already in that mode
            } catch {
                handleFetchError(error) { [weak self] in self?.loadItems(owner: owner, name: name, preserveTab: preserveTab) }
                if isCurrent() { store.isLoadingItems = false }
            }
            itemsTask = nil
        }
    }

    /// Aggregate every repo in `orgId` into the PR/issue lists: hydrate from each repo's cache first
    /// (instant), then fetch all repos' live items concurrently, delta-and-save each, and project the
    /// combined set — ordered by the panel's repo order so the per-repo sections line up. Reuses the
    /// per-repo cache/delta machinery, so an item already cached from single-repo browsing shows
    /// immediately. Repos with no open work are skipped under the default open-only filter
    /// (`OrgItemScope`). The spinner shows only when nothing is cached for the whole org.
    private func loadOrgItems(orgId: String, preserveTab: Bool = false) {
        itemsTask?.cancel()
        detailTask?.cancel()
        store.dataError = nil
        blockedByLoaded.remove("org:\(orgId)")   // a fresh load re-fetches blockers if "By blocked-by" is on
        // The "All organizations" sentinel unions every visible org's repos; a real org resolves to
        // its own. Everything downstream (the `OrgItemScope` filter, the batched-by-owner fetch, the
        // per-repo delta/cache) is scope-agnostic, so a multi-owner union just flows through.
        let repos: [Repo]
        if orgId == Org.allOrgsID {
            repos = store.allOrgRepos
        } else if let org = store.visibleOrgs.first(where: { $0.id == orgId }) {
            repos = org.repos
        } else { clearItems(); return }
        let openOnly = store.prStates == [.open] && store.issueStates == [.open]
        let repoKeys = repos
            .filter { OrgItemScope.includesRepo(open: $0.open, openOnly: openOnly) }
            .map { (owner: $0.owner, name: $0.name) }
        let prStates = store.prStates
        let issueStates = store.issueStates
        itemsTask = Task { @MainActor in
            // Only the task whose org is still current owns the spinner and the store, mirroring the
            // single-repo path: a stale aggregate for a superseded org must not stomp the newer one.
            @MainActor func isCurrent() -> Bool { currentOrg == orgId }

            var cachedPRs: [GitHubItem] = []
            var cachedIssues: [GitHubItem] = []
            for (owner, name) in repoKeys {
                let key = "\(owner)/\(name)"
                cachedPRs += await cache.loadItems(repoKey: key, kind: .pullRequest)
                cachedIssues += await cache.loadItems(repoKey: key, kind: .issue)
            }
            guard isCurrent() else { return }
            let hadCache = !cachedPRs.isEmpty || !cachedIssues.isEmpty
            if hadCache {
                store.prs = cachedPRs.map(Item.init(domain:))
                store.issues = cachedIssues.map(Item.init(domain:))
                reconcileSelectionForScope(establishing: !preserveTab)
            } else {
                store.isLoadingItems = true
            }

            do {
                let (prs, issues) = try await fetchOrgItems(
                    repoKeys: repoKeys, prStates: prStates, issueStates: issueStates)
                sessionValidated()
                guard isCurrent() else { return }
                store.isLoadingItems = false
                // The aggregate doesn't bound closed history (it's an open-work overview), so no cap.
                store.prsTruncated = false
                store.issuesTruncated = false
                // Delta against the pre-fetch cache (assembled in the same `repoKeys` order) so a
                // no-op background refresh reassigns nothing and skips reconcile — the list stays
                // static instead of rebuilding every tick, mirroring the single-repo path (#100).
                let prDelta = GitHubDelta.apply(incoming: prs, to: cachedPRs)
                let issueDelta = GitHubDelta.apply(incoming: issues, to: cachedIssues)
                if !hadCache || !prDelta.isUnchanged { store.prs = prs.map(Item.init(domain:)) }
                if !hadCache || !issueDelta.isUnchanged { store.issues = issues.map(Item.init(domain:)) }
                if !hadCache || !prDelta.isUnchanged || !issueDelta.isUnchanged {
                    reconcileSelectionForScope(establishing: !preserveTab && !hadCache)
                }
                loadBlockedByIfNeeded()   // populate the ⊘ tree when the org opens already in that mode
            } catch {
                handleFetchError(error) { [weak self] in self?.loadOrgItems(orgId: orgId, preserveTab: preserveTab) }
                if isCurrent() { store.isLoadingItems = false }
            }
            itemsTask = nil
        }
    }

    /// Fetch the org's PRs and issues, preferring one batched GraphQL request that aliases many
    /// repos (the rate-limit win — `api.batchItems`) and falling back to the per-repo path when a
    /// batch fails for any reason other than auth/rate-limit (which must abort to reach the
    /// 401-recovery path). Either way the result is delta-merged, cached, and assembled in
    /// `repoKeys` order so the per-repo sections line up.
    private func fetchOrgItems(repoKeys: [(owner: String, name: String)],
                               prStates: Set<GitHubItemState>,
                               issueStates: Set<GitHubItemState>)
        async throws -> (prs: [GitHubItem], issues: [GitHubItem]) {
        do {
            return try await fetchOrgItemsBatched(
                repoKeys: repoKeys, prStates: prStates, issueStates: issueStates)
        } catch let error as GitHubAPIError {
            switch error {
            case .unauthorized, .rateLimited:
                throw error   // affects every repo — abort & recover, don't mask it with the fallback
            default:
                Log.githubData.notice("batched org fetch failed: \(String(describing: error), privacy: .public); falling back to per-repo")
                return try await fetchOrgItemsPerRepo(
                    repoKeys: repoKeys, prStates: prStates, issueStates: issueStates)
            }
        }
    }

    /// Aggregate the org with batched GraphQL: one `api.batchItems` request per kind aliases every
    /// repo (chunked internally), so the whole org costs a handful of round-trips instead of 2×N.
    /// Repos are grouped by owner (an org's repos share its login; grouping also covers any stray
    /// owner). Each repo that resolved is delta-merged against its own cache and persisted; a repo
    /// the batch couldn't reach keeps its cached copy, so one missing repo can't blank the view.
    private func fetchOrgItemsBatched(repoKeys: [(owner: String, name: String)],
                                      prStates: Set<GitHubItemState>,
                                      issueStates: Set<GitHubItemState>)
        async throws -> (prs: [GitHubItem], issues: [GitHubItem]) {
        let api = self.api
        var prsByRepo: [String: [GitHubItem]] = [:]
        var issuesByRepo: [String: [GitHubItem]] = [:]
        for (owner, keys) in Dictionary(grouping: repoKeys, by: { $0.owner }) {
            let names = keys.map(\.name)
            async let prCall = api.batchItems(owner: owner, repos: names, kind: .pullRequest, states: prStates)
            async let issueCall = api.batchItems(owner: owner, repos: names, kind: .issue, states: issueStates)
            let (prResult, issueResult) = try await (prCall, issueCall)
            for repo in prResult { prsByRepo[repo.repositoryNameWithOwner] = repo.items }
            for repo in issueResult { issuesByRepo[repo.repositoryNameWithOwner] = repo.items }
        }
        var prs: [GitHubItem] = []
        var issues: [GitHubItem] = []
        for (owner, name) in repoKeys {
            let key = "\(owner)/\(name)"
            prs += await mergeAndCache(incoming: prsByRepo[key], repoKey: key, kind: .pullRequest)
            issues += await mergeAndCache(incoming: issuesByRepo[key], repoKey: key, kind: .issue)
        }
        return (prs, issues)
    }

    /// Delta a repo's freshly-batched items against its cache and persist the result; with no fresh
    /// items (the repo didn't resolve in the batch) fall back to the cached copy untouched.
    private func mergeAndCache(incoming: [GitHubItem]?, repoKey: String,
                               kind: GitHubItemKind) async -> [GitHubItem] {
        guard let incoming else { return await cache.loadItems(repoKey: repoKey, kind: kind) }
        let cached = await cache.loadItems(repoKey: repoKey, kind: kind)
        let merged = GitHubDelta.apply(incoming: incoming, to: cached).merged
        await cache.saveItems(merged, repoKey: repoKey, kind: kind)
        return merged
    }

    /// Fallback: fetch every repo's PRs and issues concurrently (bounded), delta each against its
    /// own cache and persist, then return the merged sets assembled in `repoKeys` order. An
    /// `unauthorized`/`rateLimited` failure aborts the whole aggregate so it reaches the
    /// 401-recovery path; any other per-repo failure falls back to that repo's cached copy so one
    /// flaky repo can't blank the view.
    private func fetchOrgItemsPerRepo(repoKeys: [(owner: String, name: String)],
                                      prStates: Set<GitHubItemState>,
                                      issueStates: Set<GitHubItemState>)
        async throws -> (prs: [GitHubItem], issues: [GitHubItem]) {
        let api = self.api
        let cache = self.cache
        let fetchOne: @Sendable (String, String) async throws
            -> (key: String, prs: [GitHubItem], issues: [GitHubItem]) = { owner, name in
            let key = "\(owner)/\(name)"
            let cachedPRs = await cache.loadItems(repoKey: key, kind: .pullRequest)
            let cachedIssues = await cache.loadItems(repoKey: key, kind: .issue)
            do {
                async let prCall = api.items(owner: owner, repo: name, kind: .pullRequest, states: prStates)
                async let issueCall = api.items(owner: owner, repo: name, kind: .issue, states: issueStates)
                let (prRes, issueRes) = try await (prCall, issueCall)
                let prMerged = GitHubDelta.apply(incoming: prRes.items, to: cachedPRs).merged
                let issueMerged = GitHubDelta.apply(incoming: issueRes.items, to: cachedIssues).merged
                await cache.saveItems(prMerged, repoKey: key, kind: .pullRequest)
                await cache.saveItems(issueMerged, repoKey: key, kind: .issue)
                return (key, prMerged, issueMerged)
            } catch let error as GitHubAPIError {
                switch error {
                case .unauthorized, .rateLimited: throw error   // affects every repo — abort & recover
                default:
                    Log.githubData.notice("org item fetch \(key, privacy: .public) failed: \(String(describing: error), privacy: .public); using cache")
                    return (key, cachedPRs, cachedIssues)
                }
            }
        }

        let maxConcurrent = 6
        var iterator = repoKeys.makeIterator()
        var results: [String: (prs: [GitHubItem], issues: [GitHubItem])] = [:]
        try await withThrowingTaskGroup(
            of: (key: String, prs: [GitHubItem], issues: [GitHubItem]).self) { group in
            for _ in 0..<maxConcurrent {
                guard let (owner, name) = iterator.next() else { break }
                group.addTask { try await fetchOne(owner, name) }
            }
            while let r = try await group.next() {
                results[r.key] = (r.prs, r.issues)
                if let (owner, name) = iterator.next() {
                    group.addTask { try await fetchOne(owner, name) }
                }
            }
        }
        var prs: [GitHubItem] = []
        var issues: [GitHubItem] = []
        for (owner, name) in repoKeys {
            if let r = results["\(owner)/\(name)"] { prs += r.prs; issues += r.issues }
        }
        return (prs, issues)
    }

    /// Keep the open item valid for the freshly-loaded list: re-hydrate it if it's still present,
    /// otherwise default to the first item of the active tab (PRs, else issues). `establishing` is
    /// true only on a scope's first population (cold open / restore / explicit repo-or-org selection);
    /// it gates the selection-follows-tab switch (`SelectionReconcile.revealTab`). A background/live
    /// refresh passes `establishing: false`, so a data update never moves the user's tab (#100) —
    /// otherwise the live fetch that lands after selecting a repo, or a status-filter reload with an
    /// issue open, yanks the view to the Issues tab.
    private func reconcileSelectionForScope(establishing: Bool) {
        let sel = store.selectedItemId
        // Reveal the tab that holds the open item — but only while establishing the scope. `revealTab`
        // returns nil (keep the current tab) on every refresh, so a data update can't flip the tab.
        if let reveal = SelectionReconcile.revealTab(
            selectedId: sel,
            currentTabHasSelected: store.listItems.contains(where: { $0.id == sel }),
            selectedIsPR: store.prs.contains(where: { $0.id == sel }),
            selectedIsIssue: store.issues.contains(where: { $0.id == sel }),
            establishing: establishing) {
            store.tab = reveal == .prs ? .prs : .issues
        }
        if let item = store.listItems.first(where: { $0.id == store.selectedItemId }) {
            // The open item is still here. Don't blank + refetch its detail if it's already loaded —
            // a refresh that keeps the same selection should leave the detail pane static (no flash),
            // mirroring `selectItem`'s reselection skip (`DetailReselectionPolicy`).
            if DetailReselectionPolicy.shouldFetchDetail(
                loadedDetailId: store.selectedItemDetail?.id, target: item.id) {
                store.selectedItemDetail = nil
                loadDetail(for: item)
            }
            return
        }
        let fallback = store.listItems.first ?? store.prs.first ?? store.issues.first
        store.selectedItemDetail = nil
        guard let first = fallback else {
            store.selectedItemId = ""
            return
        }
        store.selectedItemId = first.id
        loadDetail(for: first)
    }

    /// Fetch the hydrated detail for `item`, routed to **its own** repo (`item.repo`) rather than a
    /// single current repo — so an aggregate org list, whose items span repos, opens each detail
    /// against the right repo. The still-current selection (matched on the item's unique id) owns the
    /// spinner; a stale detail leaves it on for the newer fetch.
    private func loadDetail(for item: Item) {
        guard let repo = item.ownerRepo else { return }
        let (owner, name, number, itemId) = (repo.owner, repo.name, item.number, item.id)
        detailTask?.cancel()
        store.isLoadingDetail = true
        detailTask = Task { @MainActor in
            @MainActor func isCurrent() -> Bool { store.selectedItemId == itemId }
            do {
                let detail = try await api.itemDetail(owner: owner, repo: name, number: number)
                // Drop a stale detail if the selection moved on while this was in flight.
                guard isCurrent() else { return }
                // Carry the lazily-enriched blocked-by marker (set on the list item only, in
                // `applyBlocked`) onto the hydrated detail item — `Item(domain:)` hardcodes it nil
                // because the detail GraphQL fetch doesn't include dependencies. Without this the
                // detail item (which outranks the list item in `selectedItem`) drops the ⊘ badge.
                var hydrated = Item(domain: detail)
                if let prior = (store.prs + store.issues).first(where: { $0.id == hydrated.id }) {
                    hydrated.blocked = prior.blocked
                }
                store.selectedItemDetail = hydrated
                store.isLoadingDetail = false
            } catch {
                // A detail failure is non-fatal: the lead list item keeps showing, so don't blow
                // away the whole pane with a global error — just log it.
                if !(error is CancellationError) {
                    Log.githubData.error("detail #\(number, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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

    /// A successful authenticated fetch: the token works, so end any 401 streak and clear a pending
    /// recovery (it's now revalidated). Called on the happy path of `load()`/`loadItems()`.
    private func sessionValidated() {
        consecutiveUnauthorized = 0
        awaitingRevalidation = false
    }

    /// Funnel for a failed fetch. A 401 is special: a one-off is retried once (it may be a blip), a
    /// second in a row re-authenticates, and a 401 while a recovery is already pending just surfaces
    /// the error instead of looping (see `SessionExpiryPolicy`). `retry` re-runs the exact failed
    /// scope; it's deferred onto a fresh task so the current failing task fully unwinds (and nils its
    /// own handle) before the retry re-enters. Everything else maps to a user-facing message as before.
    private func handleFetchError(_ error: Error, retry: @escaping () -> Void) {
        if error is CancellationError { return }
        guard (error as? GitHubAPIError) == .unauthorized else {
            store.dataError = Self.message(for: error)
            return
        }
        consecutiveUnauthorized += 1
        switch SessionExpiryPolicy.reaction(consecutiveUnauthorized: consecutiveUnauthorized,
                                            recoveryPending: awaitingRevalidation) {
        case .retry:
            Task { @MainActor in retry() }
        case .reauthenticate:
            awaitingRevalidation = true
            consecutiveUnauthorized = 0
            store.dataError = nil          // the recovery sheet takes over the screen
            onUnauthorized?()
        case .surfaceError:
            consecutiveUnauthorized = 0
            store.dataError = Self.message(for: GitHubAPIError.unauthorized)
        }
    }

    /// Merge failures need their own wording: the generic `message(for:)` maps every `.http` to a
    /// "check your connection" line, but a merge's 405/409 are about the PR's state, not the network.
    /// 405 = GitHub refused the merge (not mergeable / method disabled / blocked); 409 = the head
    /// branch moved since the detail loaded (stale SHA). Everything else defers to `message(for:)`.
    private static func mergeMessage(for error: Error) -> String {
        switch error as? GitHubAPIError {
        case .http(405):
            return "GitHub wouldn't merge this pull request. It may be blocked, out of date, or that "
                 + "merge method may be disabled for this repo."
        case .http(409):
            return "This pull request changed since it loaded. Refresh and try again."
        default:
            return message(for: error)
        }
    }

    /// Edit failures need their own wording for the codes the generic `message(for:)` would flatten to
    /// "check your connection": a 403 is a permission denial (the token can't write this repo), and a
    /// 422 is GitHub rejecting the payload (e.g. an unknown label/assignee). Everything else defers.
    private static func editMessage(for error: Error) -> String {
        switch error as? GitHubAPIError {
        case .http(403):
            return "You don't have permission to edit this item."
        case .http(422):
            return "GitHub rejected the change. A label or assignee may no longer be valid."
        default:
            return message(for: error)
        }
    }

    private static func reviewerMessage(for error: Error) -> String {
        switch error as? GitHubAPIError {
        case .http(403):
            return "You don't have permission to manage reviewers on this PR."
        case .http(422):
            return "GitHub rejected the reviewer change — they may not be a valid reviewer."
        default:
            return message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        guard let apiError = error as? GitHubAPIError else {
            return "Couldn't load GitHub data. Please try again."
        }
        switch apiError {
        case .unauthorized: return "Your GitHub session expired. Sign in again to load data."
        case .rateLimited:  return "GitHub rate limit reached. Try again in a little while."
        case .notFound:     return "That repository or item is no longer available."
        // Only a genuine URLSession failure earns the "check your connection" line. Lumping the
        // cases below in with it sent users chasing a network problem that wasn't there.
        case .transport:
            return "Couldn't reach GitHub. Check your connection and try again."
        case .graphQL(let reason):
            return "GitHub refused the request: \(reason)"
        case .http(let status):
            return "GitHub returned an error (HTTP \(status)). Try again in a moment."
        case .decoding:
            return "Bosun couldn't read GitHub's response. If this keeps happening, send the "
                 + "report from Help → Copy Diagnostics."
        }
    }
}
