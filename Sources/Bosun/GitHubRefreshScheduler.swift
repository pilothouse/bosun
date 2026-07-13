import Application
import Domain
import Foundation

/// Owns the opt-in background-refresh timer (#97). A repeating `DispatchSourceTimer` fires on a fixed
/// short cadence (`RefreshPlanner.tickCadence`); each tick asks the pure `RefreshPlanner` which single
/// scoped unit — if any — to refresh next, then drives it through `GitHubDataController.backgroundRefresh`.
/// Gradual by construction (at most one unit per tick, staggered by a per-unit staleness interval) and
/// rate-limit aware (the planner pauses when the budget runs low and resumes after it resets).
///
/// `@MainActor` because it reads/writes `Store` and calls the main-actor data controller. `sync()`
/// (re)starts or stops the timer to match the current preference + auth state; the App layer calls it
/// from a `store.observe` hook, so a change to the toggle, the interval, or auth state takes effect at
/// once. Idempotent, so the frequent store notifications are cheap no-ops. Mirrors the thin-controller
/// style of `GitHubDataController` / `GitHubAuthController`.
@MainActor
final class GitHubRefreshScheduler {
    private let store: Store
    private let data: GitHubDataController
    private let api: GitHubAPI

    private var timer: DispatchSourceTimer?
    /// When each unit was last refreshed, so the planner can round-robin oldest-first. Reset whenever
    /// the timer (re)starts, so a fresh enable begins by refreshing everything once.
    private var lastRefreshed: [RefreshPlanner.Unit: Date] = [:]
    /// True while a tick's fetch is in flight. The scoped `load()` / `reloadCurrentItems()` paths don't
    /// set `store.isRefreshing` (that's the manual-refresh spinner), so this is the local guard that
    /// keeps two ticks from overlapping.
    private var inFlight = false

    init(store: Store, data: GitHubDataController, api: GitHubAPI) {
        self.store = store
        self.data = data
        self.api = api
    }

    /// Start or stop the timer to match the current preference + auth state. Idempotent: starts only
    /// when it should run and isn't already, stops only when it shouldn't and is. An interval change
    /// needs no restart — each tick reads the interval fresh from the store.
    func sync() {
        let shouldRun = store.githubAutoRefreshEnabled && store.authState == .signedIn
        if shouldRun, timer == nil {
            start()
        } else if !shouldRun, timer != nil {
            stop()
        }
    }

    private func start() {
        lastRefreshed = [:]
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + RefreshPlanner.tickCadence,
                       repeating: RefreshPlanner.tickCadence)
        timer.setEventHandler { [weak self] in Task { @MainActor in await self?.tick() } }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        inFlight = false
    }

    private func tick() async {
        // A change may have disabled it or signed out between fires — stop rather than fetch.
        guard store.githubAutoRefreshEnabled, store.authState == .signedIn else { stop(); return }
        // Respect the manual-refresh debounce, and don't stack ticks on top of each other.
        guard !store.isRefreshing, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let rateLimit = await api.rateLimitSnapshot()
        let interval = TimeInterval(store.githubAutoRefreshIntervalMinutes * 60)
        guard let unit = RefreshPlanner.next(
            now: Date(), interval: interval, lastRefreshed: lastRefreshed,
            applicable: applicableUnits(), rateLimit: rateLimit) else { return }
        lastRefreshed[unit] = Date()
        await data.backgroundRefresh(unit)
    }

    /// Which units make sense right now: the org panel always; the open scope's items only when a repo
    /// or org scope is selected (otherwise `reloadCurrentItems()` would be a no-op).
    private func applicableUnits() -> [RefreshPlanner.Unit] {
        var units: [RefreshPlanner.Unit] = [.orgList]
        if store.selectedRepoKey != nil || !store.selectedOrgId.isEmpty {
            units.append(.currentItems)
        }
        return units
    }
}
