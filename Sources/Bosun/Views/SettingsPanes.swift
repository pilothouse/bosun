import AppKit
import Domain

// The three Settings panes (#88). Unlike the rest of Bosun's hand-laid themed views, the Settings
// window is a *standard* macOS preferences window: native `NSButton`/`NSSlider`/`NSTextField` controls
// that follow the system light/dark appearance (the look the user asked for, à la NetNewsWire). Only
// the theme picker keeps custom swatch tiles, since there's no native control for it. Each pane reads
// from / writes to `Store` exactly as the retired `SettingsSheet` did (live-apply, no separate save),
// and exposes `refresh()` so the window controller can restate controls when the store changes.

/// Base for a Settings pane. A vertical `NSStackView` of rows whose required height (`paneFittingSize`)
/// drives the window's resize-to-fit. The pane itself is frame-positioned by the controller; only its
/// stack participates in Auto Layout, so reading the stack's `fittingSize` gives a clean content height.
class SettingsPane: NSView {
    let store: Store
    let stack = NSStackView()

    static let paneWidth: CGFloat = 480
    static let inset: CGFloat = 24
    static var contentWidth: CGFloat { paneWidth - inset * 2 }

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 120))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Restate controls from the store. Overridden by panes whose state can change while open.
    func refresh() {}

    /// The window content size that fits this pane: the fixed pane width and the stack's required height
    /// plus the symmetric inset.
    var paneFittingSize: NSSize {
        stack.layoutSubtreeIfNeeded()
        return NSSize(width: Self.paneWidth, height: stack.fittingSize.height + Self.inset * 2)
    }

    /// A small, secondary section caption (e.g. "Theme", "Window Opacity").
    func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// A full-content-width checkbox whose long title wraps rather than forcing the pane wider.
    func checkbox(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.lineBreakMode = .byWordWrapping
        button.cell?.wraps = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return button
    }
}

// MARK: - General

/// Skip-empty-repos, console activity badge, and iCloud connection sync — the single-toggle sections
/// that the old sheet listed separately, grouped here. Mirrors `SettingsSheet`'s wiring: each toggle
/// flips its `Store` property (which persists and `changed()`s the app), and the iCloud row is disabled
/// with a hint when the user isn't signed into iCloud.
final class GeneralPane: SettingsPane {
    private let skipBox: NSButton
    private let bellBox: NSButton
    private let iCloudBox: NSButton
    private let iCloudHint: NSTextField

    override init(store: Store) {
        skipBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        bellBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        iCloudBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        iCloudHint = NSTextField(labelWithString: "Sign in to iCloud to sync connections.")
        super.init(store: store)

        configure(skipBox, "Skip repositories without open issues or PRs", #selector(toggleSkip))
        configure(bellBox, "Show an activity badge on background console tabs", #selector(toggleBell))
        configure(iCloudBox, "Sync connections across your devices via iCloud", #selector(toggleSync))

        iCloudHint.font = .systemFont(ofSize: 11)
        iCloudHint.textColor = .secondaryLabelColor

        // iCloud checkbox + its (conditional) hint, indented under the box.
        let iCloudGroup = NSStackView(views: [iCloudBox, iCloudHint])
        iCloudGroup.orientation = .vertical
        iCloudGroup.alignment = .leading
        iCloudGroup.spacing = 3
        iCloudGroup.setCustomSpacing(3, after: iCloudBox)
        iCloudHint.translatesAutoresizingMaskIntoConstraints = false
        iCloudHint.leadingAnchor.constraint(equalTo: iCloudGroup.leadingAnchor, constant: 20).isActive = true

        stack.spacing = 12
        [skipBox, bellBox, iCloudGroup].forEach { stack.addArrangedSubview($0) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ box: NSButton, _ title: String, _ action: Selector) {
        box.title = title
        box.target = self
        box.action = action
        box.lineBreakMode = .byWordWrapping
        box.cell?.wraps = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    override func refresh() {
        skipBox.state = store.skipEmptyRepos ? .on : .off
        bellBox.state = store.terminalBellBadge ? .on : .off
        let iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        iCloudBox.isEnabled = iCloudAvailable
        iCloudBox.state = (iCloudAvailable && store.syncConnectionsICloud) ? .on : .off
        iCloudHint.isHidden = iCloudAvailable
    }

    @objc private func toggleSkip(_ sender: NSButton) { store.skipEmptyRepos = sender.state == .on }
    @objc private func toggleBell(_ sender: NSButton) { store.terminalBellBadge = sender.state == .on }
    @objc private func toggleSync(_ sender: NSButton) { store.syncConnectionsICloud = sender.state == .on }
}

// MARK: - Appearance

/// Theme picker (custom swatch tiles) + window-opacity slider. The opacity slider runs through
/// `Preferences`' easing curve and writes `store.windowAlpha` directly (no `notify()`), exactly like the
/// old sheet, so dragging it doesn't churn the window. Picking a theme sets `store.themeKey`, which
/// re-tints the *main* app (this window stays system-appearance) — `refresh()` moves the selection ring.
final class AppearancePane: SettingsPane {
    private var tiles: [ThemeTile] = []
    private let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "100%")

    override init(store: Store) {
        super.init(store: store)

        let tilesRow = NSStackView()
        tilesRow.orientation = .horizontal
        tilesRow.spacing = 10
        for theme in Theme.all {
            let tile = ThemeTile(theme: theme) { [weak self] key in self?.store.themeKey = key }
            tiles.append(tile)
            tilesRow.addArrangedSubview(tile)
        }

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(opacityChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.translatesAutoresizingMaskIntoConstraints = false
        readout.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let opacityRow = NSStackView(views: [slider, readout])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 10
        opacityRow.distribution = .fill
        opacityRow.translatesAutoresizingMaskIntoConstraints = false
        opacityRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        [sectionLabel("Theme"), tilesRow, sectionLabel("Window Opacity"), opacityRow].forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(20, after: tilesRow)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        for tile in tiles { tile.setSelected(tile.key == store.themeKey) }
        slider.doubleValue = Preferences.sliderPosition(forWindowAlpha: Double(store.windowAlpha))
        readout.stringValue = percentText
    }

    private var percentText: String {
        "\(Int((Preferences.sliderPosition(forWindowAlpha: Double(store.windowAlpha)) * 100).rounded()))%"
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        store.windowAlpha = CGFloat(Preferences.windowAlpha(forSliderPosition: sender.doubleValue))
        readout.stringValue = percentText
    }
}

/// A selectable theme tile: the 3-bar swatch from the old sheet plus the theme's name, in a rounded
/// card that shows the system accent ring when it's the active theme. Custom because there's no native
/// equivalent; it still uses system label/background colors so it sits naturally in the native window.
final class ThemeTile: FlippedView {
    let key: String
    private let onPick: (String) -> Void
    private var selected = false
    private var tracking: NSTrackingArea?
    private static let tileW: CGFloat = 98
    private static let tileH: CGFloat = 70

    init(theme: Theme, onPick: @escaping (String) -> Void) {
        key = theme.key
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: Self.tileW, height: Self.tileH))
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.tileW).isActive = true
        heightAnchor.constraint(equalToConstant: Self.tileH).isActive = true

        // 3-bar swatch, centered near the top (mirrors SettingsSheet's swatch geometry).
        let total: CGFloat = 34
        let x0 = (Self.tileW - total) / 2
        let bar0 = BoxView(bg: theme.swatch[0], radius: 4)
        bar0.frame = NSRect(x: x0, y: 13, width: 14, height: 22)
        bar0.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let bar1 = BoxView(bg: theme.swatch[1]); bar1.frame = NSRect(x: x0 + 14, y: 13, width: 11, height: 22)
        let bar2 = BoxView(bg: theme.swatch[2], radius: 4)
        bar2.frame = NSRect(x: x0 + 25, y: 13, width: 9, height: 22)
        bar2.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        addSubview(bar0); addSubview(bar1); addSubview(bar2)

        let name = label(theme.label, .systemFont(ofSize: 11, weight: .medium), .labelColor, align: .center)
        name.frame = NSRect(x: 0, y: 44, width: Self.tileW, height: 16)
        addSubview(name)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool) {
        selected = on
        layer?.borderColor = (on ? NSColor.controlAccentColor : .separatorColor).cgColor
        layer?.borderWidth = on ? 2 : 1
    }

    override func mouseDown(with event: NSEvent) { onPick(key) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        if !selected { layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        if !selected { layer?.borderColor = NSColor.separatorColor.cgColor }
    }
}

// MARK: - Account

/// GitHub sign-in / sign-out. Signed out: a default-button "Sign in to GitHub…" that closes this window
/// (so the device-flow sheet on the main window isn't behind it — replacing the old
/// `store.settingsOpen = false`) and starts sign-in. Signed in: the viewer's avatar, login, and a
/// "Sign out" button. `refresh()` rebuilds for the current `authState`.
final class AccountPane: SettingsPane {
    private let auth: GitHubAuthController
    private let row = NSStackView()

    init(store: Store, auth: GitHubAuthController) {
        self.auth = auth
        super.init(store: store)
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.addArrangedSubview(row)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if case .signedIn = store.authState {
            let user = store.currentUser
            let initials = String((user?.login ?? "?").prefix(1)).uppercased()
            let avatar = AvatarView(size: 44, cornerRadius: 22, url: user?.avatarURL,
                                    placeholderColor: .systemGray, initials: initials,
                                    initialsFont: .systemFont(ofSize: 18, weight: .semibold), initialsColor: .white)
            avatar.translatesAutoresizingMaskIntoConstraints = false
            avatar.widthAnchor.constraint(equalToConstant: 44).isActive = true
            avatar.heightAnchor.constraint(equalToConstant: 44).isActive = true

            let title = NSTextField(labelWithString: "Signed in to GitHub")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let subtitle = NSTextField(labelWithString: "@\(user?.login ?? "")")
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            let names = NSStackView(views: [title, subtitle])
            names.orientation = .vertical
            names.alignment = .leading
            names.spacing = 1

            let signOut = NSButton(title: "Sign Out", target: self, action: #selector(signOut))
            signOut.bezelStyle = .rounded
            signOut.translatesAutoresizingMaskIntoConstraints = false

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            row.setViews([avatar, names, spacer, signOut], in: .leading)
        } else {
            let info = NSTextField(labelWithString: "You're not signed in to GitHub.")
            info.font = .systemFont(ofSize: 13)
            info.textColor = .secondaryLabelColor

            let signIn = NSButton(title: "Sign in to GitHub…", target: self, action: #selector(signIn))
            signIn.bezelStyle = .rounded
            signIn.keyEquivalent = "\r"
            signIn.translatesAutoresizingMaskIntoConstraints = false

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            row.setViews([info, spacer, signIn], in: .leading)
        }
    }

    @objc private func signIn() {
        // Close Settings first so the device-flow sheet (an overlay on the main window) is unobstructed.
        window?.performClose(nil)
        auth.signIn()
    }
    @objc private func signOut() { auth.signOut() }
}
