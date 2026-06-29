import AppKit
import Domain

/// The app's Settings as a real macOS preferences window (#88): a titled `NSWindow` with a
/// System-Settings-style top `NSToolbar` of selectable icon sections (General / Appearance / Account).
/// Selecting an item swaps the content pane and resizes the window to fit, keeping the top edge fixed so
/// the toolbar doesn't jump (the geometry is the pure `SettingsPaneLayout`). The window frame persists
/// across launches via AppKit's autosave, and the last-selected pane is remembered. Replaces the modal
/// `SettingsSheet` overlay. Built programmatically, mirroring NetNewsWire's `PreferencesWindowController`.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let store: Store
    private let auth: GitHubAuthController

    /// Toolbar sections, in order. Each maps 1:1 to a cached pane built on first selection.
    private let specs: [(id: String, label: String, symbol: String)] = [
        ("general", "General", "gearshape"),
        ("appearance", "Appearance", "paintbrush"),
        ("account", "Account", "person.crop.circle")
    ]

    private var panes: [String: SettingsPane] = [:]
    private var currentPane: SettingsPane?
    private var currentIdentifier: String?

    private static let selectionDefaultsKey = "BosunSettingsSelectedPane"
    /// Titlebar + toolbar height fallback before the window is first realized (`.preference` style).
    private static let chromeFallback: CGFloat = 78

    init(store: Store, auth: GitHubAuthController) {
        self.store = store
        self.auth = auth
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsPane.paneWidth, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.title = "Settings"
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "BosunSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        window.setFrameAutosaveName("BosunSettingsWindow")

        // Restate the visible pane when the store changes externally (auth state after sign-in, iCloud
        // availability, theme picked elsewhere). Only while open, and never for opacity (which doesn't
        // notify) so a drag isn't interrupted.
        store.observe { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.currentPane?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        // Realize the window first so `contentLayoutRect` reflects the real titlebar+toolbar height
        // before the first resize-to-fit is computed.
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if currentIdentifier == nil {
            let saved = UserDefaults.standard.string(forKey: Self.selectionDefaultsKey)
            let initial = specs.first { $0.id == saved }?.id ?? specs[0].id
            window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(initial)
            switchTo(identifier: initial, animate: false)
        } else {
            currentPane?.refresh()
        }
    }

    // MARK: Pane switching

    private func pane(for identifier: String) -> SettingsPane {
        if let cached = panes[identifier] { return cached }
        let pane: SettingsPane
        switch identifier {
        case "appearance": pane = AppearancePane(store: store)
        case "account": pane = AccountPane(store: store, auth: auth)
        default: pane = GeneralPane(store: store)
        }
        panes[identifier] = pane
        return pane
    }

    private func switchTo(identifier: String, animate: Bool) {
        guard let window, let contentView = window.contentView else { return }
        let pane = self.pane(for: identifier)
        pane.refresh()
        window.title = specs.first { $0.id == identifier }?.label ?? "Settings"
        // Keep the toolbar's selected highlight on the active section regardless of how the switch was
        // triggered (a programmatic switch doesn't move it on its own).
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
        if pane === currentPane { return }

        // Size the window to the pane, top edge fixed (pure geometry).
        let fit = pane.paneFittingSize
        let frame = window.frame
        let content = window.contentLayoutRect.height
        let chrome = (content > 0 && frame.height - content > 0) ? frame.height - content : Self.chromeFallback
        let target = SettingsPaneLayout.windowFrame(
            current: .init(minX: Double(frame.minX), minY: Double(frame.minY),
                           width: Double(frame.width), height: Double(frame.height)),
            paneWidth: Double(fit.width), paneHeight: Double(fit.height), chromeHeight: Double(chrome))
        let newRect = NSRect(x: target.minX, y: target.minY, width: target.width, height: target.height)

        // Pin the pane to the content area; the stack inside sits at the top-left inset. Sizing the
        // window to the pane's fit makes the content area match, so the pane fills it cleanly.
        currentPane?.removeFromSuperview()
        pane.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pane.topAnchor.constraint(equalTo: contentView.topAnchor),
            pane.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        window.setFrame(newRect, display: true, animate: animate)
        currentPane = pane
        currentIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: Self.selectionDefaultsKey)
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        switchTo(identifier: sender.itemIdentifier.rawValue, animate: true)
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let spec = specs.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    private var identifiers: [NSToolbarItem.Identifier] { specs.map { NSToolbarItem.Identifier($0.id) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
}
