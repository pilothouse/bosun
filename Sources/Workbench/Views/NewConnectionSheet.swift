import AppKit
import Application
import Domain

/// Modal overlay for adding or editing a connection. Follows the `SettingsPopover` pattern
/// (full-bounds overlay, dim backdrop, themed card) but holds editable `NSTextField`s. Form
/// state lives in plain vars so a rebuild (kind toggle / validation error) never loses input;
/// fields are only recreated, never the source of truth.
final class NewConnectionSheet: FlippedView, NSTextViewDelegate {
    private let store: Store
    private let save: SaveConnectionUseCase
    private let editing: Domain.Connection?
    var onSaved: ((Domain.Connection) -> Void)?
    var onClose: (() -> Void)?

    // Form state — survives rebuilds.
    private var kind: ConnKind
    private var name: String
    private var host: String
    private var port: String
    private var user: String
    private var path: String
    private var customCommand: String
    private var isFavorite: Bool
    private var errors: [ConnectionValidationError] = []
    private var didFocus = false

    // Live field refs — rebuilt on every layout().
    private weak var nameField: NSTextField?
    private weak var hostField: NSTextField?
    private weak var portField: NSTextField?
    private weak var userField: NSTextField?
    private weak var pathField: NSTextField?
    private weak var customCommandView: NSTextView?

    init(store: Store, save: SaveConnectionUseCase, editing: Domain.Connection?) {
        self.store = store
        self.save = save
        self.editing = editing
        if let e = editing {
            name = e.name
            isFavorite = e.isFavorite
            customCommand = e.customCommand ?? ""
            switch e.kind {
            case let .ssh(h, p, u):
                kind = .ssh; host = h; port = String(p); user = u ?? ""; path = ""
            case let .localFolder(pth):
                kind = .folder; path = pth; host = ""; port = "22"; user = ""
            }
        } else {
            kind = .ssh; name = ""; host = ""; port = "22"; user = ""; path = ""
            customCommand = ""; isFavorite = false
        }
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks on the dim backdrop dismiss; Esc dismisses. The card (a ClickRow) swallows clicks.
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    private func syncFromFields() {
        if let f = nameField { name = f.stringValue }
        if let f = hostField { host = f.stringValue }
        if let f = portField { port = f.stringValue }
        if let f = userField { user = f.stringValue }
        if let f = pathField { path = f.stringValue }
        if let f = customCommandView { customCommand = f.string }
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.removeFromSuperview() }
        let t = store.theme
        layer?.backgroundColor = NSColor.blackA(0.45).cgColor

        // SSH cards are taller to fit the optional CUSTOM COMMAND field; folder cards stay compact.
        let cardW: CGFloat = 380
        let cardH: CGFloat = kind == .ssh ? 486 : 404
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
        buildCard(card, t: t, w: cardW, h: cardH)
        focusIfNeeded()
    }

    // MARK: Build

    private func buildCard(_ card: ClickRow, t: Theme, w: CGFloat, h: CGFloat) {
        let pad: CGFloat = 20
        let innerW = w - pad * 2

        let title = label(editing == nil ? "New connection" : "Edit connection", sys(15, .semibold), t.txt)
        title.frame = NSRect(x: pad, y: 18, width: innerW, height: 22); card.addSubview(title)

        // Kind segmented toggle.
        let gap: CGFloat = 6
        let halfW = (innerW - gap) / 2
        let sshSeg = segButton("SSH remote", selected: kind == .ssh, t: t,
                               frame: NSRect(x: pad, y: 50, width: halfW, height: 32)) { [weak self] in self?.selectKind(.ssh) }
        let dirSeg = segButton("Local folder", selected: kind == .folder, t: t,
                               frame: NSRect(x: pad + halfW + gap, y: 50, width: halfW, height: 32)) { [weak self] in self?.selectKind(.folder) }
        card.addSubview(sshSeg); card.addSubview(dirSeg)

        // Name (always).
        card.addSubview(caption("NAME", t: t, frame: NSRect(x: pad, y: 96, width: innerW, height: 12)))
        let nf = field(name, placeholder: kind == .ssh ? "prod-vm-01" : "api-gateway", t: t)
        nf.frame = NSRect(x: pad, y: 112, width: innerW, height: 26); card.addSubview(nf); nameField = nf

        // Kind-specific fields.
        if kind == .ssh {
            card.addSubview(caption("HOST", t: t, frame: NSRect(x: pad, y: 150, width: innerW, height: 12)))
            let hf = field(host, placeholder: "10.0.2.11 or gpu.ts.net", t: t)
            hf.frame = NSRect(x: pad, y: 166, width: innerW, height: 26); card.addSubview(hf); hostField = hf

            card.addSubview(caption("PORT", t: t, frame: NSRect(x: pad, y: 200, width: 96, height: 12)))
            let pf = field(port, placeholder: "22", t: t)
            pf.frame = NSRect(x: pad, y: 216, width: 96, height: 26); card.addSubview(pf); portField = pf

            card.addSubview(caption("USER (OPTIONAL)", t: t, frame: NSRect(x: pad + 108, y: 200, width: innerW - 108, height: 12)))
            let uf = field(user, placeholder: "root", t: t)
            uf.frame = NSRect(x: pad + 108, y: 216, width: innerW - 108, height: 26); card.addSubview(uf); userField = uf

            // Optional post-connect command, embedded into the launch line as `ssh … -t '<cmd>'`.
            // A tall, wrapping text box (not a single-line field) so a long command stays fully
            // visible without scrolling horizontally inside the input.
            card.addSubview(caption("CUSTOM COMMAND (OPTIONAL)", t: t, frame: NSRect(x: pad, y: 250, width: innerW, height: 12)))
            let cmdBox = commandBox(t: t, frame: NSRect(x: pad, y: 266, width: innerW, height: 58))
            card.addSubview(cmdBox)
        } else {
            card.addSubview(caption("FOLDER", t: t, frame: NSRect(x: pad, y: 150, width: innerW, height: 12)))
            let chooseW: CGFloat = 84
            let pf = field(path, placeholder: "~/dev/api-gateway", t: t)
            pf.frame = NSRect(x: pad, y: 166, width: innerW - chooseW - 8, height: 26); card.addSubview(pf); pathField = pf
            let choose = textButton("Choose…", t: t, accent: false,
                                    frame: NSRect(x: pad + innerW - chooseW, y: 166, width: chooseW, height: 26)) { [weak self] in self?.chooseFolder() }
            card.addSubview(choose)
        }

        // Favorite toggle + validation errors sit below the kind-specific fields; the SSH card's
        // taller CUSTOM COMMAND row pushes them down by 82pt (matched by the taller cardH).
        let favY: CGFloat = kind == .ssh ? 338 : 256
        let errY: CGFloat = kind == .ssh ? 372 : 290
        let fav = ClickRow(radius: 6)
        fav.hoverColor = t.hover
        fav.frame = NSRect(x: pad - 6, y: favY, width: innerW + 12, height: 26)
        fav.onClick = { [weak self] in self?.toggleFavorite() }
        let star = label(isFavorite ? "★" : "☆", sys(13), isFavorite ? t.accent : t.txt4)
        star.frame = NSRect(x: 6, y: 5, width: 16, height: 16); fav.addSubview(star)
        let favLabel = label("Add to favorites", sys(12), t.txt2)
        favLabel.frame = NSRect(x: 26, y: 5, width: innerW - 26, height: 16); fav.addSubview(favLabel)
        card.addSubview(fav)

        // Validation errors.
        if !errors.isEmpty {
            let msg = errors.map(message(for:)).joined(separator: "  ·  ")
            let err = label(msg, sys(11), Status.red, lines: 2)
            err.frame = NSRect(x: pad, y: errY, width: innerW, height: 32); card.addSubview(err)
        }

        // Buttons.
        let btnW: CGFloat = 84, btnH: CGFloat = 30, btnY = h - 44
        let cancel = textButton("Cancel", t: t, accent: false,
                                frame: NSRect(x: pad + innerW - btnW * 2 - 8, y: btnY, width: btnW, height: btnH)) { [weak self] in self?.onClose?() }
        let add = textButton(editing == nil ? "Add" : "Save", t: t, accent: true,
                             frame: NSRect(x: pad + innerW - btnW, y: btnY, width: btnW, height: btnH)) { [weak self] in self?.submit() }
        card.addSubview(cancel); card.addSubview(add)

        // Tab / Shift-Tab cycle through the visible fields. The fields are rebuilt on every layout,
        // so the key-view loop has to be re-linked here each time; AppKit derives the reverse
        // (Shift-Tab) traversal from this forward chain.
        if kind == .ssh {
            nameField?.nextKeyView = hostField
            hostField?.nextKeyView = portField
            portField?.nextKeyView = userField
            userField?.nextKeyView = customCommandView
            customCommandView?.nextKeyView = nameField
        } else {
            nameField?.nextKeyView = pathField
            pathField?.nextKeyView = nameField
        }
    }

    private func caption(_ s: String, t: Theme, frame: NSRect) -> NSTextField {
        let l = label(s, mono(9.5, .semibold), t.txt4)
        l.frame = frame
        return l
    }

    private func field(_ value: String, placeholder: String, t: Theme) -> NSTextField {
        let tf = NSTextField(string: value)
        tf.font = sys(12.5)
        tf.placeholderString = placeholder
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.lineBreakMode = .byTruncatingTail
        tf.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
        // Intentionally no target/action: pressing Return inside a field must NOT submit and
        // dismiss the sheet (that made it feel impossible to finish editing, e.g. the user field).
        // Submission is an explicit "Add"/"Save" click.
        return tf
    }

    /// A themed, wrapping, multi-line text box for the custom command — mirrors the card-style
    /// container used by the comment composer. A single-line `NSTextField` would scroll a long
    /// command horizontally; this keeps the whole command visible (wrapping, then vertical scroll).
    private func commandBox(t: Theme, frame: NSRect) -> NSView {
        let box = BoxView(bg: t.card, radius: 8, border: t.cardbr)
        box.frame = frame

        let scroll = NSScrollView(frame: NSRect(x: 1, y: 1, width: frame.width - 2, height: frame.height - 2))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]

        let tv = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: frame.height - 2))
        tv.string = customCommand
        tv.placeholder = "tmux new -n dev"
        tv.placeholderColor = t.txt4
        tv.font = sys(12.5)
        tv.textColor = t.txt
        tv.insertionPointColor = t.txt
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        // It's a shell command, not prose: turn off every "smart" substitution so a typed single
        // quote stays `'` (not a curly `'`), `--` stays `--`, paths aren't auto-linked, etc.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.delegate = self
        tv.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)

        scroll.documentView = tv
        box.addSubview(scroll)
        customCommandView = tv
        return box
    }

    /// Tab / Shift-Tab inside the command box move focus (instead of inserting a tab), keeping the
    /// form's key-view loop intact. Return is left to insert a newline — submission is an explicit
    /// "Add"/"Save" click, matching the single-line fields.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectNextKeyView(nil); return true
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil); return true
        default:
            return false
        }
    }

    // Keep the box's value in sync and repaint so the placeholder clears/returns as it empties.
    func textDidChange(_ notification: Notification) {
        if let tv = notification.object as? NSTextView {
            customCommand = tv.string
            tv.needsDisplay = true
        }
    }

    private func segButton(_ title: String, selected: Bool, t: Theme, frame: NSRect, action: @escaping () -> Void) -> ClickRow {
        let r = ClickRow(bg: selected ? t.accentbg : t.card, radius: 7)
        r.hoverColor = selected ? nil : t.hover
        r.frame = frame
        r.onClick = action
        let l = label(title, sys(12, selected ? .semibold : .regular), selected ? t.accent : t.txt3, align: .center)
        l.frame = NSRect(x: 0, y: (frame.height - 16) / 2, width: frame.width, height: 16)
        r.addSubview(l)
        return r
    }

    private func textButton(_ title: String, t: Theme, accent: Bool, frame: NSRect, action: @escaping () -> Void) -> ClickRow {
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

    private func message(for error: ConnectionValidationError) -> String {
        switch error {
        case .emptyName: return "Name is required"
        case .emptyHost: return "Host is required"
        case .invalidPort: return "Port must be 1–65535"
        case .emptyPath: return "Folder path is required"
        }
    }

    // MARK: Actions

    private func submit() {
        syncFromFields()
        let draft = makeDraft()
        let run = save
        Task { @MainActor in
            guard let outcome = try? await run(draft) else { return }
            switch outcome {
            case let .saved(connection): onSaved?(connection)
            case let .invalid(found): errors = found; needsLayout = true
            }
        }
    }

    private func makeDraft() -> ConnectionDraft {
        let resolved: Domain.ConnectionKind
        switch kind {
        case .ssh:
            let parsedPort = Int(port.trimmingCharacters(in: .whitespaces)) ?? -1
            let trimmedUser = user.trimmingCharacters(in: .whitespaces)
            resolved = .ssh(host: host, port: parsedPort, user: trimmedUser.isEmpty ? nil : trimmedUser)
        case .folder:
            resolved = .localFolder(path: path)
        }
        // Custom command is SSH-only; the use case re-trims and normalizes blank to nil.
        let trimmedCustom = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let customCmd = (kind == .ssh && !trimmedCustom.isEmpty) ? trimmedCustom : nil
        return ConnectionDraft(id: editing?.id, name: name, kind: resolved,
                               isFavorite: isFavorite, customCommand: customCmd)
    }

    private func selectKind(_ k: ConnKind) {
        syncFromFields()
        kind = k
        errors = []
        needsLayout = true
    }

    private func toggleFavorite() {
        syncFromFields()
        isFavorite.toggle()
        needsLayout = true
    }

    private func chooseFolder() {
        syncFromFields()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            needsLayout = true
        }
    }

    private func focusIfNeeded() {
        guard !didFocus, let window, let nameField else { return }
        didFocus = true
        window.makeFirstResponder(nameField)
    }
}

/// An editable `NSTextView` that draws a placeholder string when empty — `NSTextView` has no
/// built-in placeholder, unlike the bezeled `NSTextField`s the rest of the form uses.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var placeholderColor: NSColor = .placeholderTextColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: placeholderColor
        ]
        let pad = textContainer?.lineFragmentPadding ?? 0
        placeholder.draw(at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height),
                         withAttributes: attrs)
    }
}
