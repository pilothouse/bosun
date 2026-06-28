import AppKit
import Application
import Domain

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var root: BosunView!
    private var authController: GitHubAuthController!
    private var dataController: GitHubDataController!
    private var store: Store?
    let ghostty = GhosttyApp.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make hover tooltips (e.g. the truncated issue/PR titles in the right list) appear quickly
        // instead of after AppKit's ~1.5s default. `NSInitialToolTipDelay` is an undocumented but
        // long-stable default read in milliseconds; registering it (volatile, not persisted) before
        // any window exists applies it app-wide.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])

        ghostty.start()
        installMenu()
        applyDockIcon()

        let preferences = CompositionRoot.makePreferencesStore()
        let store = Store(preferences: preferences)
        self.store = store
        let services = CompositionRoot.makeConnectionServices()
        let githubServices = CompositionRoot.makeGitHubAuthServices()
        let auth = GitHubAuthController(services: githubServices, store: store)
        self.authController = auth
        // Live GitHub data: load on sign-in, clear on sign-out. The hooks fire from `auth.restore()`
        // below when a Keychain token already exists, so a returning user sees data immediately.
        let data = GitHubDataController(api: githubServices.api, cache: githubServices.cache,
                                        store: store, addComment: githubServices.addComment,
                                        mergePullRequest: githubServices.mergePullRequest,
                                        editItem: githubServices.editItem)
        self.dataController = data
        auth.onSignedIn = { [weak data] in data?.load() }
        auth.onSignedOut = { [weak data] in data?.clear() }
        // A revoked/expired token (repeated 401s) signs out and reopens the device-flow sheet.
        data.onUnauthorized = { [weak auth] in auth?.handleSessionExpired() }
        let root = BosunView(store: store, ghostty: ghostty, connections: services,
                                 auth: auth, data: data)
        self.root = root

        let win = DismissingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1340, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // Close an open View/Status dropdown on a click anywhere outside it (the menu and its toggle
        // buttons publish their no-dismiss regions in `store.menuDismissRects`). The plain overlay
        // menus can't dismiss themselves, and app-level NSEvent monitors don't see clicks here.
        win.onMouseDown = { [weak store, weak self] pointInWindow in
            // Close the detail pane's label/assignee picker on a click outside it (issue #71).
            self?.root?.windowMouseDown(at: pointInWindow)
            guard let store, store.viewMenuOpen || store.statusMenuOpen else { return }
            if !store.menuDismissRects.contains(where: { $0.contains(pointInWindow) }) {
                store.viewMenuOpen = false
                store.statusMenuOpen = false
            }
        }
        // ⌘= (the unshifted +/= key) zooms in too, matching the menu's ⌘+ without a duplicate item.
        win.onZoomIn = { [weak self] in self?.zoomIn() }
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "Bosun"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 1100, height: 720)
        win.contentView = root
        // Persist & restore the window's position and size across launches. AppKit's frame autosave
        // writes the frame to defaults on every move/resize, restores it here synchronously *before*
        // the window is shown (so there's no centered-then-jump flicker), and constrains a stale
        // off-screen frame back onto a connected display. First launch (no saved frame) falls back to
        // centered at the default size. Window geometry is OS-window state, so it lives in AppKit's
        // autosave rather than the app's `Preferences` blob — which is restored asynchronously after
        // the window is already on screen (see `restoreState`) and would otherwise cause that jump.
        if !win.setFrameUsingName("BosunMainWindow") {
            win.center()
        }
        win.setFrameAutosaveName("BosunMainWindow")
        win.makeKeyAndOrderFront(nil)
        // Traffic lights sit over our custom titlebar; keep them in place.
        win.standardWindowButton(.closeButton)?.superview?.needsLayout = true

        self.window = win
        // Opacity is applied straight to the live window; restoring prefs (below) fires this once.
        store.onWindowAlpha = { [weak win] alpha in win?.alphaValue = alpha }
        // The window title tracks the active console tab (#73); BosunView pushes the new title here
        // whenever the active tab or its label changes.
        store.onWindowTitle = { [weak win] title in win?.title = title }
        // Restore prefs first, then recompute signed-in state from the Keychain. The order matters:
        // `auth.restore()` can fire `data.load()`, which reconciles the *restored* `selectedRepoKey`
        // against the live orgs — so the key must be applied before the data load can run.
        restoreState(into: store, connections: services, preferences: preferences, then: auth)
        runAPISmokeIfRequested(githubServices.api)

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { root.focusTerminal() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Flush the latest UI state (notably the orgs panel's live scroll offset, which is mirrored into
    /// the store as the user scrolls but only written by a `persist()`) so a scroll-then-quit with no
    /// other change still restores where the user left off.
    func applicationWillTerminate(_ notification: Notification) {
        store?.persist()
    }

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
        let connectionStore = services.store
        Task { @MainActor in
            store.applyPersisted(await preferences.load())
            await Self.loadConnections(into: store, from: connectionStore)
            if let icloud = services.icloud {
                // iCloud sync (#83): a remote merge (another device wrote) re-reads the merged store
                // into the rail via `notify`; the Settings toggle flips sync on/off; the persisted
                // enabled state is applied once here so a returning user resumes syncing at launch.
                await icloud.start { [weak store] in
                    guard let store else { return }
                    Task { @MainActor in await Self.loadConnections(into: store, from: connectionStore) }
                }
                store.onSyncEnabledChanged = { enabled in Task { await icloud.setEnabled(enabled) } }
                await icloud.setEnabled(store.syncConnectionsICloud)
            }
            // Reopen the saved terminal tabs now that the connections they reference are loaded.
            self.root?.restoreTerminalTabs()
            // Measurement-only seam (`BOSUN_PERF_SEED`, used by scripts/perf-sim.sh): skip Keychain
            // auth and hold the seeded GitHub cache resident with no live fetch, so peak memory under
            // heavy synthetic data can be sampled. Off by default — the normal path below recomputes
            // signed-in state from the Keychain.
            if ProcessInfo.processInfo.environment["BOSUN_PERF_SEED"] == "1" {
                store.authState = .signedIn
                self.dataController?.loadFromCacheForPerf()
            } else {
                auth.restore()   // recompute signed-in state from the Keychain
            }
        }
    }

    /// Load (or reload) persisted connections + folders into the rail, keeping the selected connection
    /// valid (a removed one falls back to the first). Shared by launch restore and the iCloud
    /// remote-change handler (#83); a `static` so the `@Sendable` handler captures no `self`.
    @MainActor
    private static func loadConnections(into store: Store, from connectionStore: ConnectionStore) async {
        if let list = try? await connectionStore.all() {
            store.domainConnections = list
            if !list.contains(where: { $0.id.uuidString == store.selectedConnId }) {
                store.selectedConnId = list.first?.id.uuidString ?? ""
            }
        }
        store.domainFolders = (try? await connectionStore.folders()) ?? []
    }

    @objc private func newConnection() {
        root.store.editingConnId = nil
        root.store.newConnectionOpen = true
    }

    @objc private func openSettings() {
        root.store.settingsOpen = true
    }

    // MARK: Zoom (Bosun menu)

    /// True when the live terminal surface holds focus, so ⌘± should zoom just the console.
    private var isConsoleFocused: Bool { window?.firstResponder is GhosttySurfaceView }

    /// Contextual zoom (⌘+ / ⌘− / ⌘0): when the console is focused, zoom only that terminal (via
    /// libghostty's native font zoom); otherwise zoom the whole GUI — fonts, layout geometry, and the
    /// terminal font in lockstep — via `Store.uiZoom`. The main menu dispatches these before the
    /// focused view sees the keystroke, and the focus check happens at action time, so a ⌘+ typed
    /// into the terminal grows just the terminal while one typed elsewhere grows the whole app.
    @objc private func zoomIn() { isConsoleFocused ? root.zoomTerminalIn() : zoomAppIn() }
    @objc private func zoomOut() { isConsoleFocused ? root.zoomTerminalOut() : zoomAppOut() }
    @objc private func zoomActualSize() { isConsoleFocused ? root.zoomTerminalReset() : zoomAppActualSize() }

    /// Whole-app zoom: scales the entire GUI + terminal in lockstep via `Store.uiZoom`. Used by the
    /// contextual handlers above for the non-console path (the menu has no direct items for these).
    private func zoomAppIn() { root.store.uiZoom = root.store.uiZoom.zoomedIn() }
    private func zoomAppOut() { root.store.uiZoom = root.store.uiZoom.zoomedOut() }
    private func zoomAppActualSize() { root.store.uiZoom = root.store.uiZoom.reset() }

    /// Standard macOS about panel. Version + build come from the bundle's Info.plist (stamped by
    /// scripts/package-app.sh from the release tag); a bare `swift build` executable has no Info.plist,
    /// so `AppVersion` resolves those nil values to a "dev" marker rather than a misleading "0.0.0 (0)".
    /// The icon is passed explicitly: the panel reads a bundle icon file (absent in a bare executable)
    /// and does NOT fall back to `NSApp.applicationIconImage`, so without this it shows a generic icon.
    @objc private func openAbout() {
        let info = AppVersion.info(
            shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        // The panel renders "Version <applicationVersion> (<version>)", defaulting each field to the
        // Info.plist's CFBundleShortVersionString / CFBundleVersion. Override BOTH explicitly: feeding
        // the combined string into one field would double-print the build, and an empty `.version`
        // suppresses the parenthetical so a placeholder build ("0", dropped by AppVersion) shows none.
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Bosun",
            .applicationVersion: info.shortVersion,
            .version: info.build ?? "",
            .credits: aboutCredits(),
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Credits for the about panel: a link to the repo and attribution for the vendored terminal.
    /// `.link` attributes are clickable — the panel opens them in the default browser, so no handler
    /// is needed (cf. `NSWorkspace.shared.open` used elsewhere for manual link taps).
    private func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        func linked(_ text: String, _ url: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: text, attributes: base)
            s.addAttribute(.link, value: url, range: NSRange(location: 0, length: s.length))
            return s
        }
        let credits = NSMutableAttributedString()
        credits.append(linked("github.com/Jeckerson/bosun", "https://github.com/Jeckerson/bosun"))
        credits.append(NSAttributedString(string: "\n\nTerminal powered by ", attributes: base))
        credits.append(linked("ghostty / libghostty", "https://github.com/ghostty-org/ghostty"))
        return credits
    }

    @objc private func focusSearch() {
        root.focusConnectionSearch()
    }

    /// Sets the dock/app icon at runtime. A bare SwiftPM executable ships no `.app` bundle or
    /// Info.plist to carry an `.icns`, so the icon — `Resources/AppIcon.png`, the bosun's-call
    /// mark extracted from the design system (also kept as source in `Assets/AppIcon/bosun-pipe.svg`) — is
    /// bundled as a package resource and applied to `NSApp` here.
    ///
    /// The design mark is full-bleed (the squircle fills the whole canvas), but macOS sizes dock
    /// icons against a grid where the rounded-square body covers ~80% of the tile, leaving a
    /// transparent margin. Drawn full-bleed it reads slightly larger than its neighbors, so we
    /// inset it onto a transparent canvas to match the system footprint (824 of 1024 = Apple's
    /// macOS app-icon grid).
    private func applyDockIcon() {
        guard let url = Self.bundledResourceURL("AppIcon", withExtension: "png"),
              let mark = NSImage(contentsOf: url) else {
            NSLog("[icon] AppIcon.png missing from bundle resources")
            return
        }
        let side: CGFloat = 1024
        let bodyRatio: CGFloat = 824.0 / 1024.0          // Apple macOS app-icon grid
        let inset = (side - side * bodyRatio) / 2
        let icon = NSImage(size: NSSize(width: side, height: side))
        icon.lockFocus()
        mark.draw(in: NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        icon.unlockFocus()
        NSApp.applicationIconImage = icon
    }

    /// Locate a file inside the SwiftPM resource bundle (`Bosun_Bosun.bundle`) without going through
    /// the generated `Bundle.module` accessor — which `fatalError`s on first access if it can't find
    /// the bundle. That accessor only looks at `Bundle.main.bundleURL/Bosun_Bosun.bundle` (the bare
    /// executable's directory, or — fatally — a `.app`'s *root*, where the bundle is never placed) and
    /// the absolute build-machine path baked in at compile time. In a packaged `.app` the bundle lives
    /// in `Contents/Resources/` (the standard, code-signable spot), so on any machine that isn't the
    /// build machine `Bundle.module` misses both paths and aborts the process at launch — the app
    /// "bounces once and vanishes" with no window. This lookup checks the real locations and returns
    /// nil instead of crashing, so a missing resource degrades (no custom dock icon) rather than kills.
    private static func bundledResourceURL(_ name: String, withExtension ext: String) -> URL? {
        let bundleName = "Bosun_Bosun.bundle"
        // `.app`: Contents/Resources/ (resourceURL). Bare `swift run` exe: the binary's own directory
        // (bundleURL == resourceURL there). Both are where SwiftPM actually stages the bundle.
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for root in roots.compactMap({ $0 }) {
            let bundleURL = root.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        // Defensive last resort: the resource sitting loose in the main bundle.
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Bosun", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        // Zoom is grouped under a single "Zoom ▸" submenu in the Bosun menu. Each item zooms
        // contextually — the focused console, else the whole app (see `zoomIn`). Key equivalents fire
        // from a closed submenu, so the shortcuts work without opening it.
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu(title: "Zoom")
        addZoomItem(to: zoomMenu, "Zoom In", #selector(zoomIn), "+")
        addZoomItem(to: zoomMenu, "Zoom Out", #selector(zoomOut), "-")
        addZoomItem(to: zoomMenu, "Actual Size", #selector(zoomActualSize), "0")
        zoomItem.submenu = zoomMenu
        appMenu.addItem(zoomItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bosun", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        editMenu.addItem(.separator())
        let searchItem = NSMenuItem(title: "Search Connections", action: #selector(focusSearch), keyEquivalent: "k")
        searchItem.target = self
        editMenu.addItem(searchItem)
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    /// Add one ⌘-modified zoom menu item targeting self. The unshifted ⌘= compatibility shortcut is
    /// handled in `DismissingWindow.performKeyEquivalent`, not here, so the menu shows a single clean
    /// shortcut per row.
    private func addZoomItem(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = self
        menu.addItem(item)
    }
}
