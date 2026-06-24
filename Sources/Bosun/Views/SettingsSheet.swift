import AppKit
import Domain

/// Modal overlay for app settings: theme picker, window opacity, and GitHub account. Follows the
/// `NewConnectionSheet`/`ManageOrgsSheet` pattern (full-bounds dim backdrop, centered themed card,
/// backdrop/Esc/Done dismiss). Theme and opacity apply live as the user adjusts them — the card
/// rebuilds in `layout()` on every theme change — so there's no separate "save" step; Done just closes.
final class SettingsSheet: FlippedView {
    let store: Store
    private let auth: GitHubAuthController
    var onClose: (() -> Void)?
    /// Kept across rebuilds so dragging the opacity slider updates the readout live (opacity changes
    /// deliberately don't trigger a full relayout — see `Store.windowAlpha`).
    private var opacityReadout: NSTextField?
    private var didFocus = false

    init(store: Store, auth: GitHubAuthController) {
        self.store = store
        self.auth = auth
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks on the dim backdrop dismiss; Esc dismisses. The card (a ClickRow) swallows clicks.
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    // Take key focus (there's no text field to hold it) so Esc reaches `cancelOperation`.
    // BosunView restores terminal focus when the sheet closes.
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = NSColor.blackA(0.45).cgColor

        let pad: CGFloat = 20
        let cardW: CGFloat = 380
        let innerW = cardW - pad * 2
        let themes = Theme.all
        let themeRowH: CGFloat = 50

        // Fixed-content card: every section offset is deterministic, so size it up front like the
        // sibling sheets rather than tracking a running cursor.
        let rowsTop: CGFloat = 78
        let footY = rowsTop + CGFloat(themes.count) * themeRowH + 2
        let winY = footY + 40
        let accY = winY + 90
        let accRowY = accY + 34
        let btnH: CGFloat = 30
        let btnY = accRowY + 46
        let cardH = btnY + btnH + 16

        let card = ClickRow(bg: t.panel, radius: 12)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = t.line2.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 24
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.layer?.masksToBounds = false
        card.frame = NSRect(x: (bounds.width - cardW) / 2,
                            y: max(56, (bounds.height - cardH) / 2),
                            width: cardW, height: cardH)
        addSubview(card)

        let title = label("Settings", sys(15, .semibold), t.txt)
        title.frame = NSRect(x: pad, y: 18, width: innerW, height: 22); card.addSubview(title)

        // ── Appearance: theme picker. ──
        let aHdr = label("APPEARANCE", mono(9.5, .semibold), t.txt4)
        aHdr.frame = NSRect(x: pad, y: 54, width: 200, height: 14); card.addSubview(aHdr)

        // Rows run a touch wider than the inner column so the hover/selected fill has breathing room
        // around the text, matching the previous popover's look.
        let rowW = innerW + 18
        var y = rowsTop
        for th in themes {
            let on = th.key == store.themeKey
            let row = ClickRow(bg: on ? t.accentbg : nil, radius: 9)
            row.hoverColor = t.hover
            row.frame = NSRect(x: pad - 9, y: y, width: rowW, height: 46)
            // Apply the theme live; the sheet rebuilds with the new theme (Done/Esc/backdrop closes it).
            row.onClick = { [weak self] in self?.store.themeKey = th.key }
            // Swatch (3 mini bars).
            let s0 = BoxView(bg: th.swatch[0], radius: 4); s0.frame = NSRect(x: 10, y: 12, width: 14, height: 22)
            s0.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            let s1 = BoxView(bg: th.swatch[1]); s1.frame = NSRect(x: 24, y: 12, width: 11, height: 22)
            let s2 = BoxView(bg: th.swatch[2], radius: 4); s2.frame = NSRect(x: 35, y: 12, width: 9, height: 22)
            s2.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            row.addSubview(s0); row.addSubview(s1); row.addSubview(s2)

            let name = label(th.label, sys(12.5, .semibold), t.txt)
            name.frame = NSRect(x: 56, y: 8, width: rowW - 110, height: 16); row.addSubview(name)
            let note = label(th.note, sys(10.5), t.txt4)
            note.frame = NSRect(x: 56, y: 25, width: rowW - 110, height: 14); row.addSubview(note)
            if on {
                let chk = label("✓", sys(13), t.accent, align: .center)
                chk.frame = NSRect(x: rowW - 46, y: 14, width: 16, height: 16); row.addSubview(chk)
            }
            card.addSubview(row)
            y += themeRowH
        }

        let foot = label("More themes are coming — these will be fully user-configurable.", sys(11), t.txt4, lines: 2)
        foot.frame = NSRect(x: pad, y: footY, width: innerW, height: 30); card.addSubview(foot)

        // ── Window: opacity slider. ──
        let winDiv = BoxView(bg: t.line2); winDiv.frame = NSRect(x: pad, y: winY, width: innerW, height: 1); card.addSubview(winDiv)
        let wHdr = label("WINDOW", mono(9.5, .semibold), t.txt4)
        wHdr.frame = NSRect(x: pad, y: winY + 12, width: 200, height: 14); card.addSubview(wHdr)
        let opName = label("Opacity", sys(12.5, .semibold), t.txt)
        opName.frame = NSRect(x: pad, y: winY + 34, width: 120, height: 16); card.addSubview(opName)
        let readout = label(percentText, mono(10.5), t.txt4, align: .right)
        readout.frame = NSRect(x: pad + innerW - 55, y: winY + 35, width: 55, height: 14); card.addSubview(readout)
        opacityReadout = readout
        let slider = NSSlider(value: Double(store.windowAlpha),
                              minValue: Double(Preferences.minAlpha), maxValue: 1.0,
                              target: self, action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: pad, y: winY + 56, width: innerW, height: 20); card.addSubview(slider)

        // ── Account: GitHub sign-in. ──
        let accDiv = BoxView(bg: t.line2); accDiv.frame = NSRect(x: pad, y: accY, width: innerW, height: 1); card.addSubview(accDiv)
        let accHdr = label("ACCOUNT", mono(9.5, .semibold), t.txt4)
        accHdr.frame = NSRect(x: pad, y: accY + 12, width: 200, height: 14); card.addSubview(accHdr)
        if case .signedIn = store.authState {
            let dot = Dot(Status.green, 7); dot.frame.origin = NSPoint(x: pad + 1, y: accRowY + 11); card.addSubview(dot)
            let status = label("Signed in to GitHub", sys(12.5, .semibold), t.txt)
            status.frame = NSRect(x: pad + 15, y: accRowY + 7, width: innerW - 110, height: 16); card.addSubview(status)
            let signOut = textButton("Sign out", accent: false, t: t,
                                     frame: NSRect(x: pad + innerW - 77, y: accRowY, width: 77, height: 30)) { [weak self] in
                self?.auth.signOut()
            }
            card.addSubview(signOut)
        } else {
            let signIn = textButton("Sign in to GitHub", accent: true, t: t,
                                    frame: NSRect(x: pad, y: accRowY, width: innerW, height: 32)) { [weak self] in
                // Close settings so the device-flow sheet takes over cleanly (no stacked modals).
                self?.store.settingsOpen = false
                self?.auth.signIn()
            }
            card.addSubview(signIn)
        }

        // Done closes the sheet — theme and opacity are already applied live.
        let done = textButton("Done", accent: true, t: t,
                              frame: NSRect(x: pad + innerW - 84, y: btnY, width: 84, height: btnH)) { [weak self] in
            self?.onClose?()
        }
        card.addSubview(done)

        if !didFocus, let window { didFocus = true; window.makeFirstResponder(self) }
    }

    private func textButton(_ title: String, accent: Bool, t: Theme, frame: NSRect, action: @escaping () -> Void) -> ClickRow {
        let r = ClickRow(bg: accent ? t.accent : t.card, radius: 7)
        r.hoverColor = accent ? nil : t.hover
        if !accent { r.layer?.borderWidth = 1; r.layer?.borderColor = t.line2.cgColor }
        r.frame = frame
        r.onClick = action
        let l = label(title, sys(12, .semibold), accent ? t.onacc : t.txt2, align: .center)
        l.frame = NSRect(x: 0, y: (frame.height - 16) / 2, width: frame.width, height: 16)
        r.addSubview(l)
        return r
    }

    private var percentText: String { "\(Int((store.windowAlpha * 100).rounded()))%" }

    @objc private func opacityChanged(_ sender: NSSlider) {
        store.windowAlpha = CGFloat(sender.doubleValue)
        opacityReadout?.stringValue = percentText
    }
}
