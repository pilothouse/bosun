import AppKit
import Domain

/// Modal overlay for GitHub's OAuth device flow. Follows the `NewConnectionSheet`/`ManageOrgsSheet`
/// pattern (full-bounds dim backdrop, themed centered card rebuilt in `layout()`). It renders one
/// of three states off `Store.authState`: requesting a code (pending), the issued code + where to
/// enter it (authenticating), or a friendly error. Dismissing cancels the in-flight sign-in.
final class DeviceFlowSheet: FlippedView {
    private let store: Store
    private let auth: GitHubAuthController
    var onClose: (() -> Void)?

    /// Briefly shows "Copied" after the user copies the code, then reverts on the next relayout.
    private var justCopied = false

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

    override func layout() {
        super.layout()
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = NSColor.blackA(0.45).cgColor

        let cardW: CGFloat = z(380)
        let cardH = cardHeight()
        let card = ClickRow(bg: t.panel, radius: z(12))
        card.layer?.borderWidth = 1
        card.layer?.borderColor = t.line2.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = z(24)
        card.layer?.shadowOffset = CGSize(width: 0, height: z(-8))
        card.layer?.masksToBounds = false
        card.frame = NSRect(x: (bounds.width - cardW) / 2,
                            y: max(z(56), (bounds.height - cardH) / 2),
                            width: cardW, height: cardH)
        addSubview(card)
        buildCard(card, t: t, w: cardW, h: cardH)
    }

    private func cardHeight() -> CGFloat {
        switch store.authState {
        case .authenticating: return z(320)
        case .authError: return z(220)
        // The pending state grows to fit the expiry explanation, when a forced sign-in set one.
        default: return store.signInReason == nil ? z(190) : z(226)
        }
    }

    // MARK: Build

    private func buildCard(_ card: ClickRow, t: Theme, w: CGFloat, h: CGFloat) {
        let pad: CGFloat = z(24)
        let innerW = w - pad * 2

        let title = label("Sign in to GitHub", sys(15, .semibold), t.txt)
        title.frame = NSRect(x: pad, y: z(20), width: innerW, height: z(22)); card.addSubview(title)

        switch store.authState {
        case .authenticating(let grant):
            buildAuthenticating(card, t: t, pad: pad, innerW: innerW, h: h, grant: grant)
        case .authError(let message):
            buildError(card, t: t, pad: pad, innerW: innerW, h: h, message: message)
        default:
            buildPending(card, t: t, pad: pad, innerW: innerW, h: h)
        }
    }

    private func buildPending(_ card: ClickRow, t: Theme, pad: CGFloat, innerW: CGFloat, h: CGFloat) {
        var captionY: CGFloat = z(74)
        var spinnerY: CGFloat = z(104)
        // A forced sign-in (expired/revoked token) explains itself under the title; the rest of the
        // pending UI slides down to make room. A user-initiated sign-in has no reason and looks as before.
        if let reason = store.signInReason {
            let sub = label(reason, sys(12), t.txt3, align: .center, lines: 2)
            sub.frame = NSRect(x: pad, y: z(46), width: innerW, height: z(32)); card.addSubview(sub)
            captionY = z(86)
            spinnerY = z(116)
        }
        let caption = label("Requesting a device code…", sys(12.5), t.txt3, align: .center)
        caption.frame = NSRect(x: pad, y: captionY, width: innerW, height: z(16)); card.addSubview(caption)
        addSpinner(to: card, center: (pad + innerW / 2), y: spinnerY)
        addCancelButton(card, t: t, pad: pad, innerW: innerW, h: h)
    }

    private func buildAuthenticating(_ card: ClickRow, t: Theme, pad: CGFloat, innerW: CGFloat, h: CGFloat,
                                     grant: Domain.DeviceCodeGrant) {
        let cap = label("ENTER THIS CODE AT", mono(9.5, .semibold), t.txt4)
        cap.frame = NSRect(x: pad, y: z(52), width: innerW, height: z(14)); card.addSubview(cap)
        let url = label(displayURL(grant.verificationURI), sys(13, .semibold), t.accent)
        url.frame = NSRect(x: pad, y: z(67), width: innerW, height: z(18)); card.addSubview(url)

        // The user code, rendered large in a bordered box.
        let codeBox = BoxView(bg: t.card, radius: z(8), border: t.line2)
        codeBox.frame = NSRect(x: pad, y: z(92), width: innerW, height: z(56)); card.addSubview(codeBox)
        let code = label(grant.userCode, mono(26, .bold), t.txt, align: .center)
        code.frame = NSRect(x: 0, y: z(13), width: innerW, height: z(32)); codeBox.addSubview(code)

        // Copy + Open buttons.
        let gap: CGFloat = z(8)
        let halfW = (innerW - gap) / 2
        let copy = textButton(justCopied ? "Copied ✓" : "Copy code", t: t, accent: true,
                              frame: NSRect(x: pad, y: z(162), width: halfW, height: z(32))) { [weak self] in
            self?.copyCode(grant.userCode)
        }
        let open = textButton("Open in browser", t: t, accent: false,
                              frame: NSRect(x: pad + halfW + gap, y: z(162), width: halfW, height: z(32))) { [weak self] in
            self?.openVerification(grant.verificationURI)
        }
        card.addSubview(copy); card.addSubview(open)

        // Waiting indicator.
        let waiting = label("Waiting for you to authorize…", sys(11.5), t.txt3)
        waiting.frame = NSRect(x: pad + z(24), y: z(210), width: innerW - z(24), height: z(16)); card.addSubview(waiting)
        addSpinner(to: card, center: pad + z(8), y: z(210), size: z(14))

        addCancelButton(card, t: t, pad: pad, innerW: innerW, h: h)
    }

    private func buildError(_ card: ClickRow, t: Theme, pad: CGFloat, innerW: CGFloat, h: CGFloat, message: String) {
        let msg = label(message, sys(12), Status.red, lines: 3)
        msg.frame = NSRect(x: pad, y: z(56), width: innerW, height: z(48)); card.addSubview(msg)
        let retry = textButton("Try again", t: t, accent: true,
                               frame: NSRect(x: pad, y: z(112), width: innerW, height: z(32))) { [weak self] in
            self?.auth.signIn()
        }
        card.addSubview(retry)
        addCancelButton(card, t: t, pad: pad, innerW: innerW, h: h)
    }

    // MARK: Pieces

    private func addCancelButton(_ card: ClickRow, t: Theme, pad: CGFloat, innerW: CGFloat, h: CGFloat) {
        let btnW: CGFloat = z(84), btnH: CGFloat = z(30)
        let cancel = textButton("Cancel", t: t, accent: false,
                                frame: NSRect(x: pad + innerW - btnW, y: h - z(44), width: btnW, height: btnH)) { [weak self] in
            self?.onClose?()
        }
        card.addSubview(cancel)
    }

    private func addSpinner(to card: ClickRow, center x: CGFloat, y: CGFloat, size: CGFloat = z(20)) {
        let spinner = makeSpinner(size: size)
        spinner.frame.origin = NSPoint(x: x - size / 2, y: y)
        card.addSubview(spinner)
    }

    private func textButton(_ title: String, t: Theme, accent: Bool, frame: NSRect, action: @escaping () -> Void) -> ClickRow {
        let r = ClickRow(bg: accent ? t.accent : t.card, radius: z(7))
        r.hoverColor = accent ? nil : t.hover
        if !accent { r.layer?.borderWidth = 1; r.layer?.borderColor = t.line2.cgColor }
        r.frame = frame
        r.onClick = action
        let l = label(title, sys(12, .semibold), accent ? t.onacc : t.txt2, align: .center)
        l.frame = NSRect(x: 0, y: (frame.height - z(16)) / 2, width: frame.width, height: z(16))
        r.addSubview(l)
        return r
    }

    // MARK: Actions

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        justCopied = true
        needsLayout = true
        // Revert the button label shortly after, unless the state has moved on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.justCopied else { return }
            self.justCopied = false
            self.needsLayout = true
        }
    }

    private func openVerification(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Drop the scheme so the URL reads cleanly on the card (e.g. "github.com/login/device").
    private func displayURL(_ uri: String) -> String {
        guard let comps = URLComponents(string: uri), let host = comps.host else { return uri }
        return host + comps.path
    }
}
