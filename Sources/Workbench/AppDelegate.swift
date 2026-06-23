import AppKit
import Application
import Domain

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var root: WorkbenchView!
    private var authController: GitHubAuthController!
    private var dataController: GitHubDataController!
    let ghostty = GhosttyApp.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        ghostty.start()
        installMenu()

        let preferences = CompositionRoot.makePreferencesStore()
        let store = Store(preferences: preferences)
        let services = CompositionRoot.makeConnectionServices()
        let githubServices = CompositionRoot.makeGitHubAuthServices()
        let auth = GitHubAuthController(services: githubServices, store: store)
        self.authController = auth
        // Live GitHub data: load on sign-in, clear on sign-out. The hooks fire from `auth.restore()`
        // below when a Keychain token already exists, so a returning user sees data immediately.
        let data = GitHubDataController(api: githubServices.api, cache: githubServices.cache,
                                        store: store, addComment: githubServices.addComment)
        self.dataController = data
        auth.onSignedIn = { [weak data] in data?.load() }
        auth.onSignedOut = { [weak data] in data?.clear() }
        let root = WorkbenchView(store: store, ghostty: ghostty, connections: services,
                                 auth: auth, data: data)
        self.root = root

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1340, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "Workbench"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 1100, height: 720)
        win.contentView = root
        win.center()
        win.makeKeyAndOrderFront(nil)
        // Traffic lights sit over our custom titlebar; keep them in place.
        win.standardWindowButton(.closeButton)?.superview?.needsLayout = true

        self.window = win
        // Opacity is applied straight to the live window; restoring prefs (below) fires this once.
        store.onWindowAlpha = { [weak win] alpha in win?.alphaValue = alpha }
        // Restore prefs first, then recompute signed-in state from the Keychain. The order matters:
        // `auth.restore()` can fire `data.load()`, which reconciles the *restored* `selectedRepoKey`
        // against the live orgs — so the key must be applied before the data load can run.
        restoreState(into: store, connections: services, preferences: preferences, then: auth)
        runAPISmokeIfRequested(githubServices.api)

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { root.focusTerminal() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dev-only end-to-end probe of the live `GitHubAPI` client, off unless `BOSUN_API_SMOKE=1`.
    /// It fetches the viewer and their organizations and logs what decoded — proof the GraphQL +
    /// REST path works against real github.com, without wiring any of it into the UI (that's
    /// issue #4). The token comes from the Keychain (the signed-in user); set `BOSUN_GITHUB_TOKEN`
    /// to a PAT to probe without signing in. A run with no usable token logs `.unauthorized`.
    @MainActor
    private func runAPISmokeIfRequested(_ api: GitHubAPI) {
        guard ProcessInfo.processInfo.environment["BOSUN_API_SMOKE"] == "1" else { return }
        let envToken = ProcessInfo.processInfo.environment["BOSUN_GITHUB_TOKEN"]
        let client = (envToken?.isEmpty == false) ? CompositionRoot.makeGitHubAPI(token: envToken!) : api
        Task {
            do {
                let user = try await client.currentUser()
                NSLog("[api-smoke] viewer: \(user.login) (\(user.name ?? "—"))")
                let personal = try await client.viewerRepositories()
                NSLog("[api-smoke] personal repos: \(personal.count)")
                let orgs = try await client.organizations()
                NSLog("[api-smoke] organizations: \(orgs.count)")
                for org in orgs.prefix(5) {
                    let top = org.repositories.first.map {
                        "\($0.name) [issues \($0.openIssues), PRs \($0.openPullRequests)]"
                    } ?? "—"
                    NSLog("[api-smoke]   \(org.login): \(org.repositories.count) repos, e.g. \(top)")
                }
            } catch let error as GitHubAPIError {
                NSLog("[api-smoke] GitHubAPIError: \(error)")
            } catch {
                NSLog("[api-smoke] error: \(error)")
            }
        }
    }

    /// Restores saved UI preferences (theme, terminal height, selection, window opacity) and then
    /// loads persisted connections into the rail. Preferences are applied first so the restored
    /// connection selection is honored when it still exists in the loaded list; otherwise the
    /// selection falls back to the first connection. The rail starts empty until a connection is added.
    ///
    /// `auth.restore()` runs last, after the prefs are applied: it may trigger `data.load()`, which
    /// restores the saved `selectedRepoKey` by reconciling it against the live orgs — so the key has
    /// to be in place before that load can run (otherwise the auto-select would overwrite it).
    private func restoreState(into store: Store,
                              connections services: ConnectionServices,
                              preferences: PreferencesStore,
                              then auth: GitHubAuthController) {
        Task { @MainActor in
            store.applyPersisted(await preferences.load())
            if let list = try? await services.store.all() {
                store.domainConnections = list
                if !list.contains(where: { $0.id.uuidString == store.selectedConnId }) {
                    store.selectedConnId = list.first?.id.uuidString ?? ""
                }
            }
            // Reopen the saved terminal tabs now that the connections they reference are loaded.
            self.root?.restoreTerminalTabs()
            auth.restore()   // recompute signed-in state from the Keychain
        }
    }

    @objc private func newConnection() {
        root.store.editingConnId = nil
        root.store.newConnectionOpen = true
    }

    @objc private func openSettings() {
        root.store.settingsOpen = true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New Connection", action: #selector(newConnection), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
