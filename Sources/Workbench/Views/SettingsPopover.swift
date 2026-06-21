import AppKit

/// Full-bounds overlay with a theme picker card in the top-right.
final class SettingsPopover: FlippedView {
    let store: Store
    var onClose: (() -> Void)?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks on the backdrop dismiss.
    override func mouseDown(with event: NSEvent) { onClose?() }

    override func layout() {
        super.layout()
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme

        let cardW: CGFloat = 288
        let rows = Theme.all
        let cardH: CGFloat = 44 + CGFloat(rows.count) * 50 + 54
        // Card swallows clicks (ClickRow doesn't forward mouseDown).
        let card = ClickRow(bg: t.panel, radius: 12)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = t.line2.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 22
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.layer?.masksToBounds = false
        card.frame = NSRect(x: bounds.width - cardW - 14, y: 48, width: cardW, height: cardH)

        let hdr = label("APPEARANCE", mono(9.5, .semibold), t.txt4)
        hdr.frame = NSRect(x: 15, y: 13, width: 200, height: 14); card.addSubview(hdr)

        var y: CGFloat = 36
        for th in rows {
            let on = th.key == store.themeKey
            let row = ClickRow(bg: on ? t.accentbg : nil, radius: 9)
            row.hoverColor = t.hover
            row.frame = NSRect(x: 9, y: y, width: cardW - 18, height: 46)
            row.onClick = { [weak self] in
                self?.store.themeKey = th.key
                self?.store.settingsOpen = false
            }
            // Swatch (3 mini bars).
            let s0 = BoxView(bg: th.swatch[0], radius: 4); s0.frame = NSRect(x: 10, y: 12, width: 14, height: 22)
            s0.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            let s1 = BoxView(bg: th.swatch[1]); s1.frame = NSRect(x: 24, y: 12, width: 11, height: 22)
            let s2 = BoxView(bg: th.swatch[2], radius: 4); s2.frame = NSRect(x: 35, y: 12, width: 9, height: 22)
            s2.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            row.addSubview(s0); row.addSubview(s1); row.addSubview(s2)

            let name = label(th.label, sys(12.5, .semibold), t.txt); name.frame = NSRect(x: 56, y: 8, width: cardW - 110, height: 16); row.addSubview(name)
            let note = label(th.note, sys(10.5), t.txt4); note.frame = NSRect(x: 56, y: 25, width: cardW - 110, height: 14); row.addSubview(note)
            if on {
                let chk = label("✓", sys(13), t.accent, align: .center); chk.frame = NSRect(x: cardW - 46, y: 14, width: 16, height: 16); row.addSubview(chk)
            }
            card.addSubview(row)
            y += 50
        }

        let foot = label("More themes are coming — these will be fully user-configurable.", sys(11), t.txt4, lines: 2)
        foot.frame = NSRect(x: 15, y: y + 8, width: cardW - 30, height: 34); card.addSubview(foot)

        addSubview(card)
    }
}
