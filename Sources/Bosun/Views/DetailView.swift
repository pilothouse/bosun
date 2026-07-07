import AppKit
import Domain

/// Scrollable issue/PR detail for the currently-selected item.
final class DetailView: FlippedView {
    let store: Store
    private let scroll = NSScrollView()
    private let linkDelegate = MarkdownLinkDelegate()
    // Memoized Markdown renders so `rebuild()` (run on every `layout()` pass) doesn't re-parse.
    // The parsed blocks are width-independent; only the cheap per-build height measurement uses width.
    private var blocksCache: [String: [MarkdownBlock]] = [:]
    private var mdThemeKey = ""
    /// The item id the scroll offset belongs to. `rebuild()` replaces the document view (which would
    /// reset scrolling to the top); we restore the prior offset while this stays the same item — so a
    /// detail hydrating or the pane resizing doesn't yank the user back up — and let a switch to a
    /// different item start at the top.
    private var lastScrollItemId = ""

    /// Briefly true after the user copies the item's URL, so the id row flashes "Copied ✓" in place
    /// of the copy glyph. Lives on the view (not the rebuilt subviews) so it survives `rebuild()`.
    private var justCopiedURL = false

    /// Called when the user submits a comment. The view hands over the text and a completion the
    /// controller runs on the main actor: `(true, nil)` clears the composer; `(false, message)`
    /// keeps the draft so the user can retry and surfaces `message`.
    var onSubmitComment: ((String, @escaping (Bool, String?) -> Void) -> Void)?

    /// Called when the user clicks the in-pane Refresh button (shown once the detail is loaded, in the
    /// same top-right slot the hydration spinner uses). The controller force-reloads the open item.
    var onRefreshDetail: (() -> Void)?

    /// Called when the user confirms a merge. The view hands over the chosen method + edited commit
    /// text (a `PRMergeRequest`) and a completion the controller runs on the main actor: `(true,
    /// nil)` succeeded (the controller refreshes the item to `merged`); `(false, message)` keeps the
    /// form and surfaces `message`.
    var onMergePullRequest: ((PRMergeRequest, @escaping (Bool, String?) -> Void) -> Void)?

    /// Called when the user confirms closing the PR without merging. The view hands over whether to
    /// also delete the head branch (the checkbox) and a completion the controller runs on the main
    /// actor: `(true, nil)` closed (the controller refreshes the item to `closed`, hiding the section);
    /// `(false, message)` keeps the form and surfaces `message`.
    var onClosePullRequest: ((Bool, @escaping (Bool, String?) -> Void) -> Void)?

    /// Called when the user confirms closing an open issue with the chosen `IssueCloseReason`. The
    /// second argument is the parent issue number when closing as a duplicate (else nil), so the
    /// controller can post the `Duplicate of #N` marker before closing. The completion runs on the main
    /// actor: `(true, nil)` closed (the controller refreshes the item to `closed`, hiding the button);
    /// `(false, message)` keeps the form and surfaces `message`.
    var onCloseIssue: ((IssueCloseReason, Int?, @escaping (Bool, String?) -> Void) -> Void)?

    /// Called as the user types in the "close as duplicate" parent search. The view hands the query and
    /// a completion the controller runs on the main actor with the matching issues (presentation
    /// `Item`s, the current issue excluded). Debounced by the view; a blank query yields no results.
    var onSearchIssues: ((String, @escaping ([Item]) -> Void) -> Void)?

    /// Called when the user saves a title/body edit or toggles a label/assignee (issue #71). The view
    /// hands over a `GitHubItemEdit` (only the changed fields) and a completion the controller runs on
    /// the main actor: `(true, nil)` applied (the controller updates the item in place); `(false,
    /// message)` keeps the edit and surfaces `message` (a blank title / no-op is `(false, message?)`).
    var onEditItem: ((GitHubItemEdit, @escaping (Bool, String?) -> Void) -> Void)?

    /// Called when the user enters edit mode, to populate the label/assignee pickers. The view hands a
    /// completion the controller runs on the main actor with the repo's label palette + assignable users.
    var onLoadEditChoices: ((@escaping ([LabelChoice], [Assignee]) -> Void) -> Void)?

    /// Called when the user requests or removes a PR reviewer (issue #70). The view hands the action,
    /// the affected logins, and a completion the controller runs on the main actor: `(true, nil)`
    /// applied (the controller updated the detail's reviewers in place); `(false, message)` reverted.
    var onManageReviewers: ((ReviewerAction, [String], @escaping (Bool, String?) -> Void) -> Void)?

    // Composer state lives on the view (not the rebuilt subviews), so it survives `rebuild()`:
    // an in-flight post, a typed-but-unsent draft, and the last error all persist across relayouts.
    private var composerDraft = ""
    private var composerError: String?
    private var isPosting = false
    /// The id the draft belongs to, so switching items starts a fresh, empty composer.
    private var composerItemId = ""
    /// The live composer field for the current rebuild; read on submit (Return key / Send click).
    private weak var composerField: NSTextField?

    // Merge-control state, on the view for the same survives-`rebuild()` reason as the composer: the
    // chosen method, whether the method picker is open, the edited commit title/body, an in-flight
    // merge, and the last error all persist across relayouts.
    private var mergeMethod: PRMergeMethod = .merge
    private var mergeMenuOpen = false
    /// Whether the inline confirm form is expanded. Collapsed (false) shows just the merge button
    /// (GitHub-style); clicking it expands the commit fields + Confirm/Cancel.
    private var mergeConfirming = false
    private var mergeTitleDraft = ""
    private var mergeBodyDraft = ""
    private var isMerging = false
    private var mergeError: String?
    /// The open method-picker overlay for the current rebuild, added to the document *last* so it
    /// floats over the comments below rather than pushing them down. Reset every rebuild.
    private var mergeMenuOverlay: NSView?
    /// The id the merge form belongs to, so switching items resets the method/menu/error and re-seeds
    /// the commit fields from the new PR.
    private var mergeItemId = ""
    /// The live merge title/body fields for the current rebuild; read on submit.
    private weak var mergeTitleField: NSTextField?
    private weak var mergeBodyField: NSTextView?
    /// The measured height of the elastic commit-message field, so `textDidChange` only relayouts
    /// when a line is actually added/removed (not on every keystroke within a line).
    private var mergeBodyContentH: CGFloat = 0

    // Close-control state, on the view for the same survives-`rebuild()` reason as the merge state:
    // whether the inline confirm form is expanded, whether the close should also delete the head
    // branch, an in-flight close, and the last error.
    /// Whether the inline confirm form is expanded. Collapsed (false) shows just the "Close pull
    /// request" button; clicking it expands the delete-branch checkbox + Confirm/Cancel.
    private var closeConfirming = false
    /// Whether closing also deletes the head branch. On by default (GitHub's "Close + remove branch").
    private var deleteBranchChecked = true
    private var isClosing = false
    private var closeError: String?
    /// The id the close form belongs to, so switching items collapses the form and re-arms the checkbox.
    private var closeItemId = ""

    // Issue-close state — separate from the PR-close state above because issues close with a reason
    // (completed / not planned / duplicate) and have no branch to delete.
    private var isClosingIssue = false
    private var closeIssueError: String?
    private var closeIssueItemId = ""
    /// The reason the primary close button will apply — chosen from the caret dropdown, which now only
    /// *selects* (re-labelling the button); the issue closes only when the primary button is pressed.
    private var selectedCloseReason: IssueCloseReason = .completed
    /// The chosen duplicate parent (nil until picked). `.duplicate` disables the primary button until
    /// one is set; on close the number is threaded to `onCloseIssue` so a `Duplicate of #N` is posted.
    private var duplicateParentNumber: Int?
    private var duplicateParentTitle: String?
    /// The live duplicate-search text (survives `rebuild()`), its last results, and whether the results
    /// overlay is showing. The search is debounced through `dupSearchWork`.
    private var duplicateQuery = ""
    private var duplicateResults: [Item] = []
    private var duplicateMenuOpen = false
    private weak var duplicateSearchField: NSTextField?
    /// The duplicate-results overlay + its search card, in their *own* slots (not `editMenuOverlay`):
    /// a metadata picker up top and this picker down here can both be open in one rebuild. Added to the
    /// document last so the results float; the card is excluded from the click-outside dismiss check.
    private var closeDupOverlay: NSView?
    private weak var closeDupButton: NSView?
    /// The pending debounced search; cancelled on each keystroke so only the last one fires.
    private var dupSearchWork: DispatchWorkItem?

    // Edit-mode state (issue #71), on the view for the same survives-`rebuild()` reason as the
    // composer/merge state: whether the item's being edited, the in-progress title/body drafts, the
    // current label/assignee draft sets, an in-flight save, the last error, which picker (if any) is
    // open, and the fetched picker choices all persist across relayouts.
    /// The *title/body* editor is gated by the Edit (pencil) button — those fields need a batched
    /// Save/Cancel. Labels/assignees are NOT gated: they're always editable inline and each toggle
    /// saves immediately (so the pencil only governs the prose).
    private var isEditing = false
    /// The id the title/body edit belongs to, so switching items discards the drafts and exits edit mode.
    private var editItemId = ""
    private var editTitleDraft = ""
    private var editBodyDraft = ""
    private var isSavingEdit = false
    private var editError: String?
    /// Draft label names / assignee logins for the always-editable metadata rows — toggled live and
    /// saved immediately (each toggle PATCHes). Re-seeded from the item whenever the selection changes
    /// (keyed by `metaItemId`), so they reflect the open item without entering the title/body editor.
    private var metaItemId = ""
    private var editLabels: [String] = []
    private var editAssignees: [String] = []
    private var labelMenuOpen = false
    private var assigneeMenuOpen = false
    /// The reviewer picker's open state (issue #70). Reviewers have no draft set like
    /// `editLabels`/`editAssignees`: chips and the picker's ✓ read straight off `it.reviewers`
    /// (the controller updates it optimistically), so there's no separate source of truth to drift.
    private var reviewerMenuOpen = false
    /// The repo's label palette + assignable users for the pickers, fetched lazily when a picker first
    /// opens; cleared on a selection change so a different repo's choices aren't shown.
    private var labelChoices: [LabelChoice] = []
    private var assigneeChoices: [Assignee] = []
    /// The live edit title/body fields for the current rebuild; read on save.
    private weak var editTitleField: NSTextField?
    private weak var editBodyField: NSTextView?
    /// The measured height of the elastic edit-body field, so `textDidChange` only relayouts on a
    /// line add/remove (mirrors `mergeBodyContentH`).
    private var editBodyContentH: CGFloat = 0
    /// The open label/assignee picker overlay for the current rebuild, added to the document last so it
    /// floats over later content (mirrors `mergeMenuOverlay`). Reset every rebuild.
    private var editMenuOverlay: NSView?
    /// The toggle button of the open picker, captured each rebuild so a click on it (or on the overlay)
    /// is excluded from the click-outside-to-dismiss check (which would otherwise close-then-reopen it).
    private weak var editMenuButton: NSView?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply() { needsLayout = true }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        rebuild()
    }

    /// Renders `text` as themed Markdown into a vertical stack of block views sized to fit `width`,
    /// returned in a container the caller positions by frame (its height is set to fit). Text runs
    /// become selectable, link-aware text views; top-level fenced code blocks become padded, copyable
    /// boxes (`codeBlockView`). Most bodies are a single text block, so the common case is one view.
    private func markdownView(_ text: String, baseFont: NSFont, width: CGFloat) -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        let blocks = cachedBlocks(text, baseFont: baseFont)
        var y: CGFloat = 0
        for (i, block) in blocks.enumerated() {
            let v: NSView
            switch block {
            case .text(let attr): v = textBlockView(attr, width: width)
            case .code(let code): v = codeBlockView(code, baseFont: baseFont, width: width)
            }
            v.frame.origin = NSPoint(x: 0, y: y)
            container.addSubview(v)
            y += v.frame.height + (i < blocks.count - 1 ? z(10) : 0)   // gap between stacked blocks
        }
        container.frame.size.height = y
        return container
    }

    /// One Markdown text run (paragraphs/lists/headings/quotes/inline code) as a read-only, selectable
    /// text view with clickable links, sized to fit `width`.
    private func textBlockView(_ attr: NSAttributedString, width: CGFloat) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.textStorage?.setAttributedString(attr)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // flush-left like the NSTextField it replaces
        tv.textContainer?.widthTracksTextView = false
        tv.delegate = linkDelegate
        tv.linkTextAttributes = [
            .foregroundColor: store.theme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        let h = measuredHeight(of: tv, width: width)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: ceil(h))
        return tv
    }

    /// A fenced code block as a padded, rounded box (themed `accentbg2`) holding the code in a
    /// selectable monospaced text view, with a copy button floating in the top-right corner. The code
    /// text is inset on the right by a button-clear gutter so no line slips under the button.
    private func codeBlockView(_ code: String, baseFont: NSFont, width: CGFloat) -> NSView {
        let t = store.theme
        let pad = z(14), vpad = z(11), btnGutter = z(44)
        let box = BoxView(bg: t.accentbg2, radius: z(8), border: t.cardbr)
        let textW = max(z(40), width - pad - btnGutter)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 2
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: textW, height: 10))
        tv.textStorage?.setAttributedString(NSAttributedString(string: code, attributes: [
            .font: monoCodeFont(matching: baseFont),
            .foregroundColor: t.txt,
            .paragraphStyle: para,
        ]))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        let h = ceil(measuredHeight(of: tv, width: textW))
        tv.frame = NSRect(x: pad, y: vpad, width: textW, height: h)
        box.addSubview(tv)
        box.frame = NSRect(x: 0, y: 0, width: width, height: h + vpad * 2)

        let copy = ClickRow(radius: z(6))
        copy.hoverColor = t.hover
        copy.cursor = .pointingHand
        copy.toolTip = "Copy code"
        copy.frame = NSRect(x: width - z(28) - z(8), y: z(7), width: z(28), height: z(22))
        let icon = NSImageView(frame: NSRect(x: z(6), y: z(4), width: z(16), height: z(14)))
        icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        icon.contentTintColor = t.txt4
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown
        copy.addSubview(icon)
        copy.onClick = { [weak self] in self?.copyCode(code, icon: icon) }
        box.addSubview(copy)
        return box
    }

    /// A read-only, *selectable* text view rendering `text` as plain text in `font`/`color`, sized to
    /// fit `width`. Used where the text must be copyable (the title). No Markdown, no link handling;
    /// transparent background.
    private func selectableText(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // flush-left like the NSTextField it replaces
        tv.textContainer?.widthTracksTextView = false
        let h = measuredHeight(of: tv, width: width)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: ceil(h))
        return tv
    }

    private func measuredHeight(of tv: NSTextView, width: CGFloat) -> CGFloat {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
        tc.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height)
    }

    private func cachedBlocks(_ text: String, baseFont: NSFont) -> [MarkdownBlock] {
        if store.theme.key != mdThemeKey { blocksCache.removeAll(); mdThemeKey = store.theme.key }
        let key = "\(baseFont.pointSize)\u{1}\(text)"
        if let hit = blocksCache[key] { return hit }
        let rendered = renderMarkdownBlocks(text, theme: store.theme, baseFont: baseFont)
        blocksCache[key] = rendered
        return rendered
    }

    private func rebuild() {
        let t = store.theme
        layer?.backgroundColor = t.win.cgColor
        let avail = bounds.width
        guard avail > 80 else { scroll.documentView = nil; return }

        // Preserve the elastic merge-message field's focus + caret across this rebuild (it's recreated
        // below); without this, the relayout an elastic resize triggers would drop focus mid-word.
        let bodyHadFocus = mergeBodyField != nil && window?.firstResponder === mergeBodyField
        let bodySelection: NSRange? = (mergeBodyField?.selectedRanges.first as? NSValue)?.rangeValue
        // Same focus/caret preservation for the elastic edit-body field (recreated below).
        let editBodyHadFocus = editBodyField != nil && window?.firstResponder === editBodyField
        let editBodySelection: NSRange? = (editBodyField?.selectedRanges.first as? NSValue)?.rangeValue
        // Same for the duplicate-search field — an NSTextField's caret lives on its shared field editor,
        // so read the selection off `currentEditor()` rather than `selectedRanges` (NSTextView-only).
        let dupHadFocus = duplicateSearchField != nil && window?.firstResponder === duplicateSearchField?.currentEditor()
        let dupSelection: NSRange? = duplicateSearchField?.currentEditor()?.selectedRange
        mergeMenuOverlay = nil   // rebuilt below if the method picker is open; added last so it floats
        editMenuOverlay = nil    // same for the label/assignee picker
        editMenuButton = nil
        closeDupOverlay = nil    // same for the duplicate-results picker (its own slot)
        closeDupButton = nil

        let padX: CGFloat = z(26)
        let cw = avail - padX * 2
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: avail, height: 10))
        var y: CGFloat = z(20)

        guard let it = store.selectedItem else {
            let empty = label("Select an item", sys(14), t.txt4)
            empty.frame = NSRect(x: padX, y: z(30), width: cw, height: z(20)); doc.addSubview(empty)
            doc.frame.size.height = z(80); scroll.documentView = doc; lastScrollItemId = ""; return
        }

        // A new item gets a clean composer — don't carry one item's half-typed draft to the next.
        if it.id != composerItemId {
            composerItemId = it.id
            composerDraft = ""; composerError = nil; isPosting = false
        }

        // A new item also gets a fresh merge form: reset the method/menu/error and re-seed the
        // commit fields from the new PR (title → commit title, body → commit message), the same
        // defaults GitHub starts from.
        if it.id != mergeItemId {
            mergeItemId = it.id
            mergeMethod = .merge; mergeMenuOpen = false; mergeConfirming = false
            mergeError = nil; isMerging = false
            // GitHub's default merge-commit text: a "Merge pull request #N from owner/branch" title
            // and the PR title as the body. The user can edit both in the confirm form before merging.
            mergeTitleDraft = Self.defaultMergeTitle(for: it)
            mergeBodyDraft = it.title
            mergeBodyContentH = 0
        }

        // A new item collapses the close form and re-arms the delete-branch checkbox (on by default,
        // GitHub's "Close + remove branch"), so no close state leaks across a selection change.
        if it.id != closeItemId {
            closeItemId = it.id
            closeConfirming = false; isClosing = false; closeError = nil
            deleteBranchChecked = true
        }

        if it.id != closeIssueItemId {
            closeIssueItemId = it.id
            isClosingIssue = false; closeIssueError = nil
            // A new item starts from the default reason with no duplicate picked and a clean search.
            selectedCloseReason = .completed
            duplicateParentNumber = nil; duplicateParentTitle = nil
            duplicateQuery = ""; duplicateResults = []; duplicateMenuOpen = false
            dupSearchWork?.cancel()
        }

        // Selection change: re-seed the always-editable label/assignee drafts from the new item, close
        // any open picker, drop the previous repo's picker choices, and abandon any title/body edit
        // (its drafts belonged to the old item).
        if it.id != metaItemId {
            metaItemId = it.id
            editLabels = it.labels
            editAssignees = it.assignees.map(\.login)
            labelMenuOpen = false; assigneeMenuOpen = false; reviewerMenuOpen = false
            labelChoices = []; assigneeChoices = []
            isEditing = false; editError = nil
        }
        let editing = isEditing && it.id == editItemId

        func add(_ v: NSView, x: CGFloat = padX) { v.frame.origin = NSPoint(x: x, y: y); doc.addSubview(v) }

        // A clickable `#id` chip in the header id row: a `color` label that opens `url` on click
        // (no-op when `url` is empty). Returns the x just past it so the caller can place the next
        // element. Used for the plain id and for both ids inside the blocked-by marker.
        func idLink(_ text: String, url: String, color: NSColor, x: CGFloat) -> CGFloat {
            let link = ClickRow(radius: z(4))
            link.hoverColor = t.hover
            if !url.isEmpty {
                link.cursor = .pointingHand
                link.onClick = { [weak self] in self?.openItemURL(url) }
            }
            let w = fitW(text, mono(12))
            link.frame = NSRect(x: x, y: y, width: w + z(6), height: z(20))
            let lbl = label(text, mono(12), color)
            lbl.frame = NSRect(x: z(3), y: z(2), width: w, height: z(16)); link.addSubview(lbl)
            doc.addSubview(link)
            return link.frame.maxX
        }

        // Type row. The kind badge (PR/ISSUE/EPIC) carries the item's *state* color (open green,
        // closed/merged, …) on its text and border — the standalone status label is gone. Its
        // top-right slot now hosts the hydration spinner, so loading never shifts the body down.
        let typeLabel: String = it.epic ? "EPIC" : (it.kind == .pr ? "PR" : "ISSUE")
        let tb = badge(typeLabel, fg: it.statusColor, border: it.statusColor, mono: false)
        tb.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(tb)
        // Repo name (plain), then the current-issue id row. Normally the plain `#id` (accent) opens
        // the item on github.com; under the "By blocked-by" grouping the id is replaced by the
        // dependency marker `⊘ #<blocker> → #<this>` (red, both ids linking to their pages) so the
        // blocker reads right after the repo. A copy-link glyph trails the row.
        let rnX = padX + tb.frame.width + z(10)
        let repoLabel = label(it.repo, mono(12), t.txt3)
        let repoW = fitW(repoLabel)
        repoLabel.frame = NSRect(x: rnX, y: y + z(2), width: repoW, height: z(16)); doc.addSubview(repoLabel)

        var headerRX = rnX + repoW + z(5)
        if let blocked = it.blocked {
            let cross = label("⊘", sys(12), Status.red, align: .center)
            cross.frame = NSRect(x: headerRX, y: y + z(2), width: z(14), height: z(16)); doc.addSubview(cross)
            headerRX = idLink("#\(blocked)", url: "https://github.com/\(it.repo)/issues/\(blocked)",
                              color: Status.red, x: headerRX + z(16))
            let arrow = label("→", sys(12), Status.red)
            arrow.frame = NSRect(x: headerRX + z(1), y: y + z(2), width: z(14), height: z(16)); doc.addSubview(arrow)
            headerRX = idLink(it.num, url: it.url, color: Status.red, x: headerRX + z(19))
        } else {
            headerRX = idLink(it.num, url: it.url, color: t.accent, x: headerRX)
        }
        // Copy-link affordance: a small clickable glyph that copies the item's web URL and flashes
        // "Copied ✓" in place. Sits just past the id/marker, left of the top-right hydration slot.
        if !it.url.isEmpty {
            let copy = ClickRow(radius: z(5))
            copy.hoverColor = t.hover
            copy.cursor = .pointingHand
            copy.onClick = { [weak self] in self?.copyItemURL(it.url) }
            let cx = headerRX + z(4)
            if justCopiedURL {
                let done = label("Copied ✓", mono(11), t.accent)
                let w = fitW(done)
                copy.frame = NSRect(x: cx, y: y, width: w + z(8), height: z(20))
                done.frame = NSRect(x: z(4), y: z(3), width: w, height: z(14)); copy.addSubview(done)
            } else {
                copy.frame = NSRect(x: cx, y: y, width: z(20), height: z(20))
                let glyph = label("⧉", mono(13), t.txt4, align: .center)
                glyph.frame = NSRect(x: 0, y: z(2), width: z(20), height: z(16)); copy.addSubview(glyph)
            }
            doc.addSubview(copy)
        }
        // Top-right slot: while hydrating, a spinner + "Loading details…" (the lead item renders
        // instantly; this signals the body/tasks/comments/checks are still loading and vanishes in
        // place when they land — no vertical shift). Once loaded, a Refresh button in the same slot
        // force-reloads the open item; re-shows this spinner while it reloads.
        if store.isLoadingDetail && store.selectedItemDetail == nil {
            let spinner = makeSpinner(size: z(14))
            spinner.frame.origin = NSPoint(x: padX + cw - z(16), y: y + z(2)); doc.addSubview(spinner)
            let loading = label("Loading details…", sys(11.5), t.txt4, align: .right)
            loading.frame = NSRect(x: padX + cw - z(160), y: y + z(2), width: z(138), height: z(16)); doc.addSubview(loading)
        } else if store.selectedItemDetail != nil {
            let refresh = ClickRow(radius: z(5))
            refresh.hoverColor = t.hover
            refresh.cursor = .pointingHand
            refresh.toolTip = "Refresh"
            refresh.onClick = { [weak self] in self?.onRefreshDetail?() }
            refresh.frame = NSRect(x: padX + cw - z(22), y: y, width: z(22), height: z(20))
            let iv = NSImageView(frame: NSRect(x: z(3), y: z(2), width: z(16), height: z(16)))
            iv.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            iv.contentTintColor = t.txt4
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iv.imageScaling = .scaleProportionallyUpOrDown
            refresh.addSubview(iv)
            doc.addSubview(refresh)

            // Edit (pencil), just left of Refresh — enters inline edit mode. Hidden while already
            // editing (Save/Cancel below take over) and while a save is in flight.
            if !editing && onEditItem != nil {
                let edit = ClickRow(radius: z(5))
                edit.hoverColor = t.hover
                edit.cursor = .pointingHand
                edit.toolTip = "Edit"
                edit.onClick = { [weak self] in self?.beginEdit() }
                edit.frame = NSRect(x: padX + cw - z(48), y: y, width: z(22), height: z(20))
                let ev = NSImageView(frame: NSRect(x: z(3), y: z(2), width: z(16), height: z(16)))
                ev.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit")
                ev.contentTintColor = t.txt4
                ev.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                ev.imageScaling = .scaleProportionallyUpOrDown
                edit.addSubview(ev)
                doc.addSubview(edit)
            }
        }
        y += z(30)

        // Title — an editable field in edit mode, else the selectable (read-only) copyable text.
        if editing {
            let titleBox = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
            titleBox.frame = NSRect(x: padX, y: y, width: cw, height: z(40))
            let tf = NSTextField(string: editTitleDraft)
            tf.font = sys(18, .bold); tf.placeholderString = "Title"
            tf.isBezeled = false; tf.drawsBackground = false; tf.focusRingType = .none
            tf.textColor = t.txt; tf.lineBreakMode = .byTruncatingTail
            tf.delegate = self
            tf.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
            tf.isEnabled = !isSavingEdit
            tf.frame = NSRect(x: z(12), y: z(9), width: cw - z(24), height: z(24))
            titleBox.addSubview(tf); editTitleField = tf
            add(titleBox); y += z(40) + z(11)
        } else {
            editTitleField = nil
            let title = selectableText(it.title, font: sys(21, .bold), color: t.txt, width: cw)
            add(title); y += title.frame.height + z(11)
        }

        // Author row.
        let avatar = AvatarView(size: z(20), cornerRadius: z(10), url: it.authorAvatarURL,
                                placeholderColor: it.authorColor, initials: it.authorInitials,
                                initialsFont: sys(9, .bold), initialsColor: .hex(0x0d0f13),
                                ring: it.isAgent ? it.authorColor : nil)
        avatar.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(avatar)
        var rx = padX + z(28)
        let auth = label(it.author, sys(12, .semibold), t.txt2); auth.frame = NSRect(x: rx, y: y + z(3), width: fitW(auth), height: z(16)); doc.addSubview(auth); rx += auth.frame.width + z(9)
        let opened = label("opened \(it.age)", sys(12), t.txt4); opened.frame = NSRect(x: rx, y: y + z(3), width: fitW(opened), height: z(16)); doc.addSubview(opened); rx += opened.frame.width + z(9)
        if let branch = it.branch {
            // GitHub-style head → base: the PR's branch and, once the detail is hydrated, the branch a
            // merge lands on. Base-less (lead) rows show just the head branch until the detail arrives.
            let text = it.baseRef.map { "⎇ \(branch) → \($0)" } ?? "⎇ \(branch)"
            let b = badge(text, fg: t.accent, bg: t.accentbg2)
            b.frame.origin = NSPoint(x: rx, y: y); doc.addSubview(b); rx += b.frame.width + z(9)
        }
        if let a = it.add, let d = it.del {
            let diff = label("+\(a) −\(d)", mono(10.5), t.txt3); diff.frame = NSRect(x: rx, y: y + z(3), width: z(90), height: z(16)); doc.addSubview(diff); rx += z(96)
        }
        y += z(30)

        // Metadata section: labels, assignees, milestone (issue #71). LABELS and ASSIGNEES are
        // *always* editable inline — each chip carries a remove ✕ and the caption is followed by a
        // "＋" opener, so a label/assignee can be added or removed without entering the title/body
        // editor; every toggle saves immediately. Both rows always render (the "＋" opener keeps them
        // non-empty) so an item with none still offers a way to add one. Milestone stays read-only —
        // it isn't one of the four editable fields. Built on the reusable `metaRow` helper.
        let labelViews: [NSView] = editLabels.map { name in
            editableChip(name, color: editLabelColor(name, it: it), t: t,
                         onRemove: { [weak self] in self?.toggleLabel(name) })
        }
        let labelBtn = pickerButton("＋", t: t, on: labelMenuOpen, tooltip: "Add label",
                                    onClick: { [weak self] in self?.toggleEditMenu(.labels) })
        y = metaRow("LABELS", labelViews, into: doc, t: t, x: padX, y: y, width: cw, accessory: labelBtn)
        if labelMenuOpen {
            editMenuOverlay = makeLabelMenu(t: t, x: labelBtn.frame.minX, y: y - z(6), width: z(240))
            editMenuButton = labelBtn
        }

        let assigneeViews: [NSView] = editAssignees.map { login in
            editableAssigneeChip(login, it: it, t: t,
                                 onRemove: { [weak self] in self?.toggleAssignee(login) })
        }
        let assigneeBtn = pickerButton("＋", t: t, on: assigneeMenuOpen, tooltip: "Add assignee",
                                       onClick: { [weak self] in self?.toggleEditMenu(.assignees) })
        y = metaRow("ASSIGNEES", assigneeViews, into: doc, t: t, x: padX, y: y, width: cw, accessory: assigneeBtn)
        if assigneeMenuOpen {
            editMenuOverlay = makeAssigneeMenu(t: t, x: assigneeBtn.frame.minX, y: y - z(6), width: z(240))
            editMenuButton = assigneeBtn
        }

        // Reviewers (issue #70) — PR-only. Each chip shows the reviewer's review-state badge; a
        // *pending* (requested) reviewer carries a remove ✕ (only pending requests can be cancelled).
        // The "＋" opener after the caption requests from the repo's assignable users (same pool as
        // the assignee picker). Mirrors the ASSIGNEES row; both render through `metaRow`.
        if it.kind == .pr {
            let reviewerViews: [NSView] = it.reviewers.map { r in
                reviewerChip(r, t: t,
                             onRemove: r.isPending ? { [weak self] in self?.toggleReviewer(r.login) } : nil)
            }
            let reviewerBtn = pickerButton("＋", t: t, on: reviewerMenuOpen, tooltip: "Add reviewer",
                                           onClick: { [weak self] in self?.toggleEditMenu(.reviewers) })
            y = metaRow("REVIEWERS", reviewerViews, into: doc, t: t, x: padX, y: y, width: cw, accessory: reviewerBtn)
            if reviewerMenuOpen {
                editMenuOverlay = makeReviewerMenu(t: t, x: reviewerBtn.frame.minX, y: y - z(6), width: z(240))
                editMenuButton = reviewerBtn
            }
        }

        if let milestone = it.milestone, !milestone.isEmpty {
            y = metaRow("MILESTONE", [milestonePill(milestone, t: t)], into: doc, t: t, x: padX, y: y, width: cw)
        }

        // Body — an editable elastic field in edit mode (mirrors the merge commit-message field), with
        // a Save/Cancel bar for the title+body; else the read-only Markdown card. Task-list checkboxes
        // (`- [ ]` / `- [x]`) render inline via swift-markdown (see MarkdownRenderer.visitUnorderedList);
        // `it.tasks` is intentionally left unread so they aren't drawn a second time (#86).
        if editing {
            editBodyField = nil
            let textW = cw - z(20)
            let contentH = max(z(140), Self.textHeight(editBodyDraft, width: textW - z(8), font: sys(13.5)))
            editBodyContentH = contentH
            let boxH = contentH + z(18)
            let bodyBox = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
            bodyBox.frame = NSRect(x: padX, y: y, width: cw, height: boxH)
            let tv = NSTextView(frame: NSRect(x: z(10), y: z(9), width: textW, height: boxH - z(18)))
            tv.string = editBodyDraft
            tv.font = sys(13.5); tv.textColor = t.txt
            tv.drawsBackground = false; tv.isRichText = false
            tv.delegate = self
            tv.textContainerInset = NSSize(width: z(4), height: z(4))
            tv.textContainer?.lineFragmentPadding = 0
            tv.isEditable = !isSavingEdit
            tv.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
            bodyBox.addSubview(tv); editBodyField = tv
            doc.addSubview(bodyBox); y += boxH + z(14)

            let saveW = z(72), cancelW = z(80), gap = z(8), barH = z(30)
            if isSavingEdit {
                let spinner = makeSpinner(size: z(15))
                spinner.frame.origin = NSPoint(x: padX, y: y + z(6)); doc.addSubview(spinner)
                let lbl = label("Saving…", sys(12.5, .semibold), t.txt3)
                lbl.frame = NSRect(x: padX + z(24), y: y + z(7), width: cw - z(30), height: z(16)); doc.addSubview(lbl)
            } else {
                let save = ClickRow(bg: t.accent, radius: z(8))
                save.frame = NSRect(x: padX, y: y, width: saveW, height: barH)
                save.onClick = { [weak self] in self?.saveEdit() }
                let sl = label("Save", sys(12, .semibold), t.onacc, align: .center)
                sl.frame = NSRect(x: 0, y: z(8), width: saveW, height: z(16)); save.addSubview(sl)
                doc.addSubview(save)

                let cancel = ClickRow(bg: t.card, radius: z(8))
                cancel.layer?.borderWidth = 1; cancel.layer?.borderColor = t.cardbr.cgColor
                cancel.frame = NSRect(x: padX + saveW + gap, y: y, width: cancelW, height: barH)
                cancel.onClick = { [weak self] in self?.cancelEdit() }
                let cl = label("Cancel", sys(12, .semibold), t.txt2, align: .center)
                cl.frame = NSRect(x: 0, y: z(8), width: cancelW, height: z(16)); cancel.addSubview(cl)
                doc.addSubview(cancel)
            }
            y += barH + z(8)
            if let editError {
                let err = label(editError, sys(11), Status.red, lines: 0)
                err.preferredMaxLayoutWidth = cw
                err.frame = NSRect(x: padX, y: y, width: cw, height: z(32)); doc.addSubview(err); y += z(24)
            }
            y += z(12)
        } else {
            editBodyField = nil
            let bodyText = markdownView(it.body, baseFont: sys(13.5), width: cw - z(34))
            let cardH = bodyText.frame.height + z(30)
            let card = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
            card.frame = NSRect(x: padX, y: y, width: cw, height: cardH)
            bodyText.frame.origin = NSPoint(x: z(17), y: z(15)); card.addSubview(bodyText)
            doc.addSubview(card); y += cardH + z(20)
        }

        // PR checks. The ACTIONS header is a disclosure: clicking it toggles the global,
        // persisted collapsed state (`store.prChecksCollapsed`). The X/Y tally stays in the
        // header even when collapsed so the pass summary is always readable.
        if it.kind == .pr && !it.checks.isEmpty {
            let passed = it.checks.filter { $0.statusText == "passed" }.count
            let collapsed = store.prChecksCollapsed
            let header = ClickRow(bg: nil, radius: z(6))
            header.hoverColor = t.hover
            header.frame = NSRect(x: padX, y: y, width: cw, height: z(18))
            header.onClick = { [weak store] in store?.prChecksCollapsed.toggle() }
            // A solid disclosure triangle that rotates with state: ▶ (collapsed) → ▼ (expanded).
            let caret = label(collapsed ? "▶" : "▼", sys(8), t.txt4, align: .center)
            caret.frame = NSRect(x: 0, y: z(4), width: z(14), height: z(12)); header.addSubview(caret)
            let hdr = label("ACTIONS · \(passed)/\(it.checks.count) passing", mono(9.5, .semibold), t.txt4)
            hdr.frame = NSRect(x: z(15), y: z(2), width: cw - z(15), height: z(14)); header.addSubview(hdr)
            doc.addSubview(header); y += z(24)
            if !collapsed {
                let box = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
                let rowH: CGFloat = z(31)
                box.frame = NSRect(x: padX, y: y, width: cw, height: rowH * CGFloat(it.checks.count))
                var cy: CGFloat = 0
                for (i, c) in it.checks.enumerated() {
                    // Rows with a run URL become clickable (hand cursor + hover); URL-less rows stay inert.
                    let link = (c.url?.isEmpty == false) ? c.url : nil
                    let row: FlippedView
                    if let link {
                        let cr = ClickRow(bg: nil, radius: 0)
                        cr.frame = NSRect(x: 0, y: cy, width: cw, height: rowH)
                        cr.hoverColor = t.hover
                        cr.cursor = .pointingHand
                        cr.onClick = { [weak self] in self?.openItemURL(link) }
                        row = cr
                    } else {
                        row = FlippedView(frame: NSRect(x: 0, y: cy, width: cw, height: rowH))
                    }
                    let icon = BoxView(bg: .hexA(UInt32(c.color.toHex()), 0.12), radius: z(5), border: c.color)
                    icon.frame = NSRect(x: z(14), y: z(8), width: z(16), height: z(16))
                    icon.addSubview(centeredGlyph(c.icon, sys(9), c.color, in: icon.frame.size)); row.addSubview(icon)
                    let nm = label(c.name, sys(12.5, .medium), t.txt2); nm.frame = NSRect(x: z(40), y: z(7), width: cw - z(220), height: z(16)); row.addSubview(nm)
                    let stt = label(c.statusText, mono(10.5), c.color, align: .right); stt.frame = NSRect(x: cw - z(180), y: z(7), width: z(110), height: z(16)); row.addSubview(stt)
                    let dur = label(c.dur, mono(10), t.txt4, align: .right); dur.frame = NSRect(x: cw - z(62), y: z(7), width: z(48), height: z(16)); row.addSubview(dur)
                    if i < it.checks.count - 1 {
                        let sep = BoxView(bg: t.line); sep.frame = NSRect(x: 0, y: rowH - z(1), width: cw, height: z(1)); row.addSubview(sep)
                    }
                    box.addSubview(row); cy += rowH
                }
                doc.addSubview(box); y += box.frame.height
            }
            y += z(22)
        }

        // PR changed files. Mirrors the ACTIONS disclosure above: the header toggles the global,
        // persisted `store.prFilesCollapsed`, and the count stays visible when collapsed. The list
        // is what a detail fetch hydrated (issues never reach here; a PR with no files renders none).
        if it.kind == .pr && !it.files.isEmpty {
            let collapsed = store.prFilesCollapsed
            let header = ClickRow(bg: nil, radius: z(6))
            header.hoverColor = t.hover
            header.frame = NSRect(x: padX, y: y, width: cw, height: z(18))
            header.onClick = { [weak store] in store?.prFilesCollapsed.toggle() }
            let caret = label(collapsed ? "▶" : "▼", sys(8), t.txt4, align: .center)
            caret.frame = NSRect(x: 0, y: z(4), width: z(14), height: z(12)); header.addSubview(caret)
            let hdr = label("FILES CHANGED · \(it.files.count)", mono(9.5, .semibold), t.txt4)
            hdr.frame = NSRect(x: z(15), y: z(2), width: cw - z(15), height: z(14)); header.addSubview(hdr)
            doc.addSubview(header); y += z(24)
            if !collapsed {
                let box = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
                let rowH: CGFloat = z(31)
                box.frame = NSRect(x: padX, y: y, width: cw, height: rowH * CGFloat(it.files.count))
                var fy: CGFloat = 0
                for (i, f) in it.files.enumerated() {
                    let row = FlippedView(frame: NSRect(x: 0, y: fy, width: cw, height: rowH))
                    let icon = BoxView(bg: .hexA(UInt32(f.color.toHex()), 0.12), radius: z(5), border: f.color)
                    icon.frame = NSRect(x: z(14), y: z(8), width: z(16), height: z(16))
                    icon.addSubview(centeredGlyph(f.glyph, sys(9, .bold), f.color, in: icon.frame.size)); row.addSubview(icon)
                    // Middle-truncate so the filename stays readable when the directory path is long.
                    let nm = label(f.path, mono(11.5), t.txt2); nm.lineBreakMode = .byTruncatingMiddle
                    nm.frame = NSRect(x: z(40), y: z(7), width: cw - z(175), height: z(16)); row.addSubview(nm)
                    let diff = label("+\(f.add) −\(f.del)", mono(10.5), t.txt3, align: .right)
                    diff.frame = NSRect(x: cw - z(130), y: z(7), width: z(116), height: z(16)); row.addSubview(diff)
                    if i < it.files.count - 1 {
                        let sep = BoxView(bg: t.line); sep.frame = NSRect(x: 0, y: rowH - z(1), width: cw, height: z(1)); row.addSubview(sep)
                    }
                    box.addSubview(row); fy += rowH
                }
                doc.addSubview(box); y += box.frame.height
            }
            y += z(22)
        }

        // Merge control (open PRs only). A closed/merged PR has no merge affordance; an open one
        // shows the split-button when mergeable, or a disabled bar with the reason when not. The
        // "Close pull request" button rides the same row, right-aligned (GitHub keeps close beside
        // merge); its confirm form (delete-branch checkbox + Confirm/Cancel) expands just below.
        if it.kind == .pr && it.state == .open {
            y = layoutMergeSection(for: it, into: doc, t: t, padX: padX, cw: cw, y: y)
            if closeConfirming || isClosing {
                y = layoutCloseSection(for: it, into: doc, t: t, padX: padX, cw: cw, y: y)
            }
        }

        // Comments. The header is a disclosure mirroring ACTIONS/FILES CHANGED: it toggles the
        // global, persisted `store.prCommentsCollapsed`. Only the thread collapses — the composer
        // below stays visible so a comment can always be posted.
        let commentsCollapsed = store.prCommentsCollapsed
        let cHeader = ClickRow(bg: nil, radius: z(6))
        cHeader.hoverColor = t.hover
        cHeader.frame = NSRect(x: padX, y: y, width: cw, height: z(18))
        cHeader.onClick = { [weak store] in store?.prCommentsCollapsed.toggle() }
        let cCaret = label(commentsCollapsed ? "▶" : "▼", sys(8), t.txt4, align: .center)
        cCaret.frame = NSRect(x: 0, y: z(4), width: z(14), height: z(12)); cHeader.addSubview(cCaret)
        let chdr = label("COMMENTS · \(it.comments.count)", mono(9.5, .semibold), t.txt4)
        chdr.frame = NSRect(x: z(15), y: z(2), width: cw - z(15), height: z(14)); cHeader.addSubview(chdr)
        doc.addSubview(cHeader); y += z(24)
        if !commentsCollapsed {
            for cm in it.comments {
                let av = AvatarView(size: z(26), cornerRadius: z(13), url: cm.avatarURL,
                                    placeholderColor: cm.color, initials: cm.initials,
                                    initialsFont: sys(10, .bold), initialsColor: .hex(0x0d0f13),
                                    ring: cm.badge == "agent" ? cm.color : nil)
                av.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(av)
                let bubbleW = cw - z(37)
                let body = markdownView(cm.body, baseFont: sys(12.5), width: bubbleW - z(26))
                let bubbleH = body.frame.height + z(38)
                let bubble = BoxView(bg: t.card, radius: z(11), border: t.cardbr)
                bubble.frame = NSRect(x: padX + z(37), y: y, width: bubbleW, height: bubbleH)
                let an = label(cm.author, sys(12, .bold), t.txt); an.frame = NSRect(x: z(13), y: z(11), width: z(200), height: z(16)); bubble.addSubview(an)
                let tm = label(cm.time, sys(11), t.txt4, align: .right); tm.frame = NSRect(x: bubbleW - z(90), y: z(11), width: z(76), height: z(16)); bubble.addSubview(tm)
                if !cm.badge.isEmpty {
                    let bg = badge(cm.badge, fg: t.accent, border: t.accent); bg.frame.origin = NSPoint(x: z(13) + fitW(an) + z(8), y: z(9)); bubble.addSubview(bg)
                }
                body.frame.origin = NSPoint(x: z(13), y: z(30)); bubble.addSubview(body)
                doc.addSubview(bubble); y += bubbleH + z(13)
            }

            // Composer. The avatar is the signed-in viewer (real image once it loads, initials until
            // then); the field is editable and Return/Comment posts the comment. The button row sits
            // below the text box (outside it), matching the Merge PR split-button style: for open
            // issues "Close issue" (primary) + "▾" (caret dropdown) on the left, green "Comment" on
            // the right; for PRs/closed issues only "Comment" on the right.
            let cav = AvatarView(size: z(26), cornerRadius: z(13), url: store.viewer?.avatarURL,
                                 placeholderColor: store.viewer?.color ?? Status.dim,
                                 initials: store.viewer?.initials ?? "?",
                                 initialsFont: sys(10, .bold), initialsColor: .hex(0x0d0f13))
            cav.frame.origin = NSPoint(x: padX, y: y); doc.addSubview(cav)

            let compW = cw - z(37)
            let showCloseMenu = it.kind == .issue && it.state == .open
            let comp = BoxView(bg: t.card, radius: z(10), border: t.cardbr)
            comp.frame = NSRect(x: padX + z(37), y: y, width: compW, height: z(38))

            let field = NSTextField(string: composerDraft)
            field.font = sys(12.5)
            field.placeholderString = "Write a comment…"
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.textColor = t.txt
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            field.target = self
            field.action = #selector(composerReturn)   // Return submits; fires only on Enter, not on blur
            field.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
            field.isEnabled = !isPosting
            field.frame = NSRect(x: z(12), y: z(9), width: compW - z(24), height: z(20))
            comp.addSubview(field)
            composerField = field
            doc.addSubview(comp); y += z(46)

            // Close-as-duplicate parent picker, between the comment field and the button row (so the
            // whole row shifts down naturally). Until a parent is picked it's a search field with a
            // floating results overlay; once picked it's a removable chip. Duplicate reason only.
            let dupX = padX + z(37)
            if showCloseMenu && selectedCloseReason == .duplicate {
                if let n = duplicateParentNumber {
                    let chip = editableChip("#\(n) \(duplicateParentTitle ?? "")", color: nil, t: t,
                                            onRemove: { [weak self] in
                        self?.duplicateParentNumber = nil; self?.duplicateParentTitle = nil
                        self?.needsLayout = true
                    })
                    chip.frame.origin = NSPoint(x: dupX, y: y + z(2)); doc.addSubview(chip)
                    y += z(30)
                } else {
                    let card = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
                    card.frame = NSRect(x: dupX, y: y, width: compW, height: z(32))
                    let mag = label("⌕", sys(13), t.txt4)
                    mag.frame = NSRect(x: z(10), y: z(7), width: z(16), height: z(18)); card.addSubview(mag)
                    let dupField = NSTextField(string: duplicateQuery)
                    dupField.font = sys(12.5)
                    dupField.placeholderString = "Find the duplicate's parent issue…"
                    dupField.isBezeled = false
                    dupField.drawsBackground = false
                    dupField.focusRingType = .none
                    dupField.textColor = t.txt
                    dupField.lineBreakMode = .byTruncatingTail
                    dupField.delegate = self
                    dupField.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
                    dupField.isEnabled = !isClosingIssue
                    dupField.frame = NSRect(x: z(30), y: z(7), width: compW - z(40), height: z(18))
                    card.addSubview(dupField)
                    duplicateSearchField = dupField
                    closeDupButton = card
                    doc.addSubview(card); y += z(40)

                    // Results overlay: built here, added to `doc` last so it floats over the content
                    // below. Only while the query is non-empty; an empty result set says so.
                    if duplicateMenuOpen && !duplicateQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        let rows = duplicateResults.prefix(20).map { m in
                            ChecklistRow(title: "\(m.num)  \(m.title)", tint: nil, on: false,
                                         action: { [weak self] in
                                self?.duplicateParentNumber = m.number
                                self?.duplicateParentTitle = m.title
                                self?.duplicateQuery = ""; self?.duplicateResults = []
                                self?.duplicateMenuOpen = false
                                self?.needsLayout = true
                            })
                        }
                        closeDupOverlay = makeChecklistMenu(t: t, x: dupX, y: card.frame.maxY + z(4),
                                                            width: compW, empty: "No matching issues",
                                                            rows: Array(rows))
                    }
                }
            }

            // Button row below the text box. Green Comment stays right-aligned; the Close split-button
            // (open issues only) sits immediately to its left. Mirrors the Merge PR split-button pattern.
            let btnRowH: CGFloat = z(34)
            let btnX = padX + z(37)
            let commentW: CGFloat = z(88)
            let commentX = btnX + compW - commentW

            if showCloseMenu {
                let caretW: CGFloat = z(30), gap: CGFloat = z(5), closeGap: CGFloat = z(8)
                let primaryTitle = selectedCloseReason.buttonTitle
                let primaryW = fitW(primaryTitle, sys(12, .semibold)) + z(24)   // dynamic: reasons differ in width
                let closeGroupW = primaryW + gap + caretW
                let closeGroupX = max(btnX, commentX - closeGap - closeGroupW)   // clamp: never past the left edge
                if isClosingIssue {
                    let spinner = makeSpinner(size: z(14))
                    spinner.frame.origin = NSPoint(x: closeGroupX + primaryW / 2, y: y + z(10))
                    doc.addSubview(spinner)
                } else {
                    // The primary Close is disabled until a duplicate parent is chosen (duplicate only).
                    let closeEnabled = selectedCloseReason != .duplicate || duplicateParentNumber != nil
                    let primary = ClickRow(bg: t.txt.withAlphaComponent(closeEnabled ? 0.08 : 0.04), radius: z(8))
                    primary.frame = NSRect(x: closeGroupX, y: y, width: primaryW, height: btnRowH)
                    if closeEnabled {
                        primary.hoverColor = t.hover
                        primary.onClick = { [weak self] in self?.submitCurrentClose() }
                    }
                    let pl = label(primaryTitle, sys(12, .semibold), closeEnabled ? t.txt2 : t.txt4, align: .center)
                    pl.frame = NSRect(x: 0, y: z(9), width: primaryW, height: z(16)); primary.addSubview(pl)
                    doc.addSubview(primary)

                    let caret = ClickRow(bg: t.txt.withAlphaComponent(0.08), radius: z(8))
                    caret.frame = NSRect(x: closeGroupX + primaryW + gap, y: y, width: caretW, height: btnRowH)
                    caret.onClick = { [weak self, weak caret] in
                        guard let self, let caret else { return }
                        let menu = NSMenu()
                        let reasons: [IssueCloseReason] = [.completed, .notPlanned, .duplicate]
                        for (i, reason) in reasons.enumerated() {
                            let item = NSMenuItem(title: reason.menuTitle,
                                                  action: #selector(self.closeIssueMenuAction(_:)),
                                                  keyEquivalent: "")
                            item.tag = i
                            item.target = self
                            item.state = (reason == self.selectedCloseReason) ? .on : .off
                            menu.addItem(item)
                        }
                        menu.popUp(positioning: nil,
                                   at: NSPoint(x: 0, y: caret.bounds.height + z(4)),
                                   in: caret)
                    }
                    let cl = label("▾", sys(11), t.txt2, align: .center)
                    cl.frame = NSRect(x: 0, y: z(9), width: caretW, height: z(16)); caret.addSubview(cl)
                    doc.addSubview(caret)
                }
            }

            if isPosting {
                let spinner = makeSpinner(size: z(14))
                spinner.frame.origin = NSPoint(x: commentX + commentW / 2, y: y + z(10))
                doc.addSubview(spinner)
            } else {
                let commentBtn = ClickRow(bg: Status.green, radius: z(8))
                commentBtn.frame = NSRect(x: commentX, y: y, width: commentW, height: btnRowH)
                commentBtn.onClick = { [weak self] in self?.submitComposer() }
                let cl = label("Comment", sys(12, .semibold), .white, align: .center)
                cl.frame = NSRect(x: 0, y: z(9), width: commentW, height: z(16)); commentBtn.addSubview(cl)
                doc.addSubview(commentBtn)
            }
            y += btnRowH + z(8)

            if let composerError {
                let err = label(composerError, sys(11), Status.red, lines: 0)
                err.preferredMaxLayoutWidth = compW
                err.frame = NSRect(x: padX + z(37), y: y, width: compW, height: z(30))
                doc.addSubview(err); y += z(22)
            }
            if let closeIssueError {
                let err = label(closeIssueError, sys(11), Status.red, lines: 0)
                err.preferredMaxLayoutWidth = compW
                err.frame = NSRect(x: padX + z(37), y: y, width: compW, height: z(30))
                doc.addSubview(err); y += z(22)
            }
        }
        y += z(8)

        // The open method / label / assignee / duplicate pickers float over later content: added last
        // so they're on top, and their height (not position) extends the document so they can't be clipped.
        if let menu = mergeMenuOverlay { doc.addSubview(menu) }
        if let menu = editMenuOverlay { doc.addSubview(menu) }
        if let menu = closeDupOverlay { doc.addSubview(menu) }
        doc.frame.size.height = max(y + z(10),
                                    (mergeMenuOverlay?.frame.maxY ?? 0) + z(10),
                                    (editMenuOverlay?.frame.maxY ?? 0) + z(10),
                                    (closeDupOverlay?.frame.maxY ?? 0) + z(10))

        // Replacing the document view resets the scroll to the top. Restore the prior offset when
        // we're re-rendering the same item (a detail hydrating, a comment landing, a resize) so the
        // user stays put; only a switch to a different item starts at the top. Clamp to the new
        // content height so a now-shorter document (e.g. the checks section collapsed) can't overscroll.
        let sameItem = it.id == lastScrollItemId
        let priorOrigin = scroll.contentView.bounds.origin
        scroll.documentView = doc
        if sameItem {
            let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: priorOrigin.x, y: min(priorOrigin.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        lastScrollItemId = it.id

        // Restore focus + caret to the rebuilt merge-message field so an elastic resize doesn't
        // interrupt typing (the field above was just recreated under a new document view).
        if bodyHadFocus, let tv = mergeBodyField {
            window?.makeFirstResponder(tv)
            if let bodySelection { tv.setSelectedRange(bodySelection) }
        }
        // Same for the rebuilt edit-body field, so growing it by a line doesn't drop focus mid-word.
        if editBodyHadFocus, let tv = editBodyField {
            window?.makeFirstResponder(tv)
            if let editBodySelection { tv.setSelectedRange(editBodySelection) }
        }
        // Same for the rebuilt duplicate-search field, so each keystroke (which relayouts to refresh
        // the results overlay) doesn't drop focus. The caret lives on the field editor.
        if dupHadFocus, let tf = duplicateSearchField {
            window?.makeFirstResponder(tf)
            if let dupSelection { tf.currentEditor()?.selectedRange = dupSelection }
        }
    }

    // MARK: Metadata section (reusable)

    /// Lay out one metadata row — an uppercase caption in a fixed left gutter, then a left-to-right
    /// flow of already-sized value views that wraps within `width` — into `doc` starting at `y`.
    /// Returns the new `y`; unchanged when both `values` and `accessory` are empty, so callers skip
    /// empty rows for free. The optional `accessory` (the "＋" picker opener) is placed just after the
    /// caption word, so the add affordance reads as part of the row's label rather than trailing the
    /// chips. The reusable primitive behind the LABELS/ASSIGNEES/REVIEWERS/MILESTONE rows.
    private func metaRow(_ caption: String, _ values: [NSView], into doc: NSView,
                         t: Theme, x: CGFloat, y: CGFloat, width: CGFloat,
                         accessory: NSView? = nil) -> CGFloat {
        guard !values.isEmpty || accessory != nil else { return y }
        // Three fixed columns so every row lines up: the caption word, then the "＋" opener (same x on
        // every row), then the chips/value. The opener slot is reserved even on a row without one
        // (MILESTONE), so its value stays in the same column as the others' chips.
        let capCol = z(64), plusSlot = z(18), gap = z(6), lineGap = z(7)
        let capFont = mono(9.5, .semibold)
        let cap = label(caption, capFont, t.txt4)
        cap.frame = NSRect(x: x, y: y + z(4), width: capCol - z(4), height: z(13)); doc.addSubview(cap)
        if let accessory {
            accessory.frame.origin = NSPoint(x: x + capCol,
                                             y: y + ((z(20) - accessory.frame.height) / 2).rounded())
            doc.addSubview(accessory)
        }
        let startX = x + capCol + plusSlot + gap, maxX = x + width
        // The opener (when present) sets the first line's minimum height, so a chip-less row still
        // reserves its full height and adjacent rows' openers can't overlap. `z(14)` trailing gap
        // keeps the rows comfortably apart.
        var cx = startX, cy = y, lineH: CGFloat = accessory != nil ? z(20) : 0
        for v in values {
            if cx > startX && cx + v.frame.width > maxX { cx = startX; cy += lineH + lineGap; lineH = 0 }
            v.frame.origin = NSPoint(x: cx, y: cy); doc.addSubview(v)
            cx += v.frame.width + gap; lineH = max(lineH, v.frame.height)
        }
        return cy + lineH + z(14)
    }

    /// The milestone shown as a neutral chip with a diamond glyph.
    private func milestonePill(_ title: String, t: Theme) -> BoxView {
        badge("◇ \(title)", fg: t.txt3, bg: t.hover, border: t.cardbr, mono: false)
    }

    // MARK: Edit mode (issue #71)

    /// Enter the title/body editor for the open item (the Edit pencil). Labels/assignees are edited
    /// inline without this, so it only seeds the title/body drafts. A no-op if nothing's selected.
    private func beginEdit() {
        guard let it = store.selectedItem else { return }
        isEditing = true
        editItemId = it.id
        editTitleDraft = it.title
        editBodyDraft = it.body
        editError = nil; isSavingEdit = false
        editBodyContentH = 0
        needsLayout = true
    }

    /// Leave the title/body editor without saving its drafts (label/assignee toggles already saved).
    private func cancelEdit() {
        isEditing = false
        editError = nil
        needsLayout = true
    }

    /// Save the title/body edit (the labels/assignees save live on toggle). No-ops while a save is in
    /// flight; sends only the fields that actually changed; an edit that changed neither just exits.
    /// Hands a `GitHubItemEdit` to the controller via `onEditItem`, which calls back to exit on success
    /// or surface the error (keeping the form) on failure — mirrors `performMerge`/`submitComposer`.
    private func saveEdit() {
        guard !isSavingEdit, let onEditItem, let it = store.selectedItem else { return }
        let title = editTitleField?.stringValue ?? editTitleDraft
        let body = editBodyField?.string ?? editBodyDraft
        editTitleDraft = title; editBodyDraft = body
        var edit = GitHubItemEdit()
        if title != it.title { edit.title = title }
        if body != it.body { edit.body = body }
        guard !edit.isEmpty else { isEditing = false; needsLayout = true; return }
        editError = nil
        isSavingEdit = true
        needsLayout = true
        onEditItem(edit) { [weak self] ok, message in
            guard let self else { return }
            self.isSavingEdit = false
            if ok { self.isEditing = false; self.editError = nil }
            else if let message { self.editError = message }   // keep the form open so the user can retry
            self.needsLayout = true
        }
    }

    /// Which metadata picker a toggle targets. The reviewer picker reuses the assignee-user choices.
    private enum EditPicker { case labels, assignees, reviewers }

    /// Open one picker (closing the others), or close it if it's already open. Lazily fetches the
    /// repo's label/assignee choices the first time any picker opens (cleared on a selection change).
    private func toggleEditMenu(_ picker: EditPicker) {
        labelMenuOpen = (picker == .labels) ? !labelMenuOpen : false
        assigneeMenuOpen = (picker == .assignees) ? !assigneeMenuOpen : false
        reviewerMenuOpen = (picker == .reviewers) ? !reviewerMenuOpen : false
        if (labelMenuOpen || assigneeMenuOpen || reviewerMenuOpen) && labelChoices.isEmpty && assigneeChoices.isEmpty {
            loadEditChoices()
        }
        needsLayout = true
    }

    /// Fetch the repo's label palette + assignable users for the pickers (idempotent — the controller
    /// caches per repo). The selected item is captured so a result that lands after the user moved on
    /// is dropped.
    private func loadEditChoices() {
        let wantId = metaItemId
        onLoadEditChoices? { [weak self] labels, assignees in
            guard let self, self.metaItemId == wantId else { return }
            self.labelChoices = labels
            self.assigneeChoices = assignees
            self.needsLayout = true
        }
    }

    /// Close any open picker — the click-outside-to-dismiss path (and a selection change). The
    /// window routes every mouse-down here via `BosunView`/`DismissingWindow`; we only act when a
    /// picker is open and the click missed both the overlay and its toggle button (else a click on the
    /// button would close-then-reopen it, and a click on a menu row wouldn't register).
    func dismissPickers(forWindowClickAt pointInWindow: NSPoint) {
        guard labelMenuOpen || assigneeMenuOpen || reviewerMenuOpen || duplicateMenuOpen else { return }
        if let overlay = editMenuOverlay, overlay.convert(overlay.bounds, to: nil).contains(pointInWindow) { return }
        if let button = editMenuButton, button.convert(button.bounds, to: nil).contains(pointInWindow) { return }
        if let overlay = closeDupOverlay, overlay.convert(overlay.bounds, to: nil).contains(pointInWindow) { return }
        if let button = closeDupButton, button.convert(button.bounds, to: nil).contains(pointInWindow) { return }
        labelMenuOpen = false; assigneeMenuOpen = false; reviewerMenuOpen = false
        duplicateMenuOpen = false
        needsLayout = true
    }

    /// Add/remove a label and save the new set immediately (GitHub-sidebar style). The picker stays
    /// open so several can be toggled in a row.
    private func toggleLabel(_ name: String) {
        var labels = editLabels
        if let i = labels.firstIndex(of: name) { labels.remove(at: i) } else { labels.append(name) }
        commitEdit(GitHubItemEdit(labels: labels), applyLabels: labels)
    }

    /// Add/remove an assignee and save the new set immediately.
    private func toggleAssignee(_ login: String) {
        var assignees = editAssignees
        if let i = assignees.firstIndex(of: login) { assignees.remove(at: i) } else { assignees.append(login) }
        commitEdit(GitHubItemEdit(assignees: assignees), applyAssignees: assignees)
    }

    /// Request a reviewer, or cancel their pending request (issue #70). The action is derived from the
    /// reviewer's current state on the open item: a still-pending request is removed, anyone else is
    /// (re)requested. The controller owns the optimistic store update + revert; here we just fire and
    /// surface a failure message. The picker stays open so several can be toggled in a row.
    private func toggleReviewer(_ login: String) {
        guard let onManageReviewers, let it = store.selectedItem else { return }
        let isPending = it.reviewers.contains { $0.login == login && $0.isPending }
        editError = nil
        onManageReviewers(isPending ? .remove : .request, [login]) { [weak self] ok, message in
            guard let self else { return }
            if !ok, let message { self.editError = message }
            self.needsLayout = true
        }
    }

    /// Optimistically apply a label/assignee toggle to the drafts and PATCH it; revert + surface the
    /// error on failure. The controller's success path updates the store's canonical labels/assignees.
    private func commitEdit(_ edit: GitHubItemEdit, applyLabels: [String]? = nil, applyAssignees: [String]? = nil) {
        guard let onEditItem else { return }
        let priorLabels = editLabels, priorAssignees = editAssignees
        if let applyLabels { editLabels = applyLabels }
        if let applyAssignees { editAssignees = applyAssignees }
        editError = nil
        needsLayout = true
        onEditItem(edit) { [weak self] ok, message in
            guard let self else { return }
            if !ok {
                self.editLabels = priorLabels; self.editAssignees = priorAssignees
                if let message { self.editError = message }
            }
            self.needsLayout = true
        }
    }

    /// The display color for a draft label: the repo palette's color if known, else the color the
    /// item already carries for it (so a pre-existing colored label keeps its tint), else neutral.
    private func editLabelColor(_ name: String, it: Item) -> NSColor? {
        labelChoices.first { $0.name == name }?.color ?? it.labelColors[name]
    }

    /// The presentation assignee for a draft login: prefer the item's own (has the avatar), then the
    /// picker choices, falling back to a minimal initials-only chip via the canonical actor rule.
    private func editAssignee(_ login: String, it: Item) -> Assignee {
        it.assignees.first { $0.login == login }
            ?? assigneeChoices.first { $0.login == login }
            ?? Assignee(domain: GitHubActor(login: login))
    }

    /// A removable label chip: a tinted pill (label color, or neutral) whose trailing ✕ — and *only*
    /// the ✕ — removes it (so a stray click on the always-visible chip can't drop a label). Sized to
    /// fit so `metaRow` flows it like any other value view.
    private func editableChip(_ text: String, color: NSColor?, t: Theme, onRemove: @escaping () -> Void) -> NSView {
        let fg = color ?? t.txt3
        let textW = fitW(text, sys(11.5)), xW = z(15)
        let w = z(10) + textW + z(2) + xW
        let chip = BoxView(bg: color.map { .hexA(UInt32($0.toHex()), 0.15) } ?? t.hover,
                           radius: z(9), border: color ?? t.cardbr)
        chip.frame = NSRect(x: 0, y: 0, width: w, height: z(20))
        let lbl = label(text, sys(11.5), fg)
        lbl.frame = NSRect(x: z(10), y: z(3), width: textW, height: z(14)); chip.addSubview(lbl)
        chip.addSubview(removeButton(fg: fg, t: t, x: z(10) + textW, w: xW, h: z(20), onRemove: onRemove))
        return chip
    }

    /// A removable assignee chip: avatar + login, whose trailing ✕ (only) removes it.
    private func editableAssigneeChip(_ login: String, it: Item, t: Theme, onRemove: @escaping () -> Void) -> NSView {
        let a = editAssignee(login, it: it)
        let nameW = fitW(login, sys(11.5)), xW = z(15)
        let w = z(22) + nameW + z(2) + xW
        let chip = BoxView(bg: t.hover, radius: z(11), border: t.cardbr)
        chip.frame = NSRect(x: 0, y: 0, width: w, height: z(22))
        let av = AvatarView(size: z(16), cornerRadius: z(8), url: a.avatarURL, placeholderColor: a.color,
                            initials: a.initials, initialsFont: sys(7.5, .bold), initialsColor: .hex(0x0d0f13))
        av.frame.origin = NSPoint(x: z(3), y: z(3)); chip.addSubview(av)
        let nm = label(login, sys(11.5), t.txt2)
        nm.frame = NSRect(x: z(22), y: z(4), width: nameW, height: z(14)); chip.addSubview(nm)
        chip.addSubview(removeButton(fg: t.txt3, t: t, x: z(22) + nameW, w: xW, h: z(22), onRemove: onRemove))
        return chip
    }

    /// A reviewer chip (issue #70): avatar + login + a review-state badge. A *pending* reviewer's
    /// chip carries a trailing ✕ (`onRemove` non-nil) to cancel the request; a submitted review has
    /// no ✕ (it can't be removed through this endpoint). Sized to fit so `metaRow` flows it.
    private func reviewerChip(_ r: Reviewer, t: Theme, onRemove: (() -> Void)?) -> NSView {
        let nameW = fitW(r.login, sys(11.5))
        let badgeInfo = r.stateBadge
        let stateBadge = badge(badgeInfo.text, fg: badgeInfo.color, border: badgeInfo.color, mono: false)
        let badgeW = stateBadge.frame.width
        let xW: CGFloat = onRemove != nil ? z(15) : z(8)
        let w = z(22) + nameW + z(6) + badgeW + xW
        let chip = BoxView(bg: t.hover, radius: z(11), border: t.cardbr)
        chip.frame = NSRect(x: 0, y: 0, width: w, height: z(22))
        let av = AvatarView(size: z(16), cornerRadius: z(8), url: r.avatarURL, placeholderColor: r.color,
                            initials: r.initials, initialsFont: sys(7.5, .bold), initialsColor: .hex(0x0d0f13))
        av.frame.origin = NSPoint(x: z(3), y: z(3)); chip.addSubview(av)
        let nm = label(r.login, sys(11.5), t.txt2)
        nm.frame = NSRect(x: z(22), y: z(4), width: nameW, height: z(14)); chip.addSubview(nm)
        stateBadge.frame.origin = NSPoint(x: z(22) + nameW + z(6), y: (z(22) - stateBadge.frame.height) / 2)
        chip.addSubview(stateBadge)
        if let onRemove {
            chip.addSubview(removeButton(fg: t.txt3, t: t, x: z(22) + nameW + z(6) + badgeW, w: xW, h: z(22), onRemove: onRemove))
        }
        return chip
    }

    /// The ✕ hit-target placed at the trailing edge of a removable chip — a small hover-highlighted
    /// click area so removal needs a deliberate click on the ✕, not anywhere on the chip.
    private func removeButton(fg: NSColor, t: Theme, x: CGFloat, w: CGFloat, h: CGFloat,
                              onRemove: @escaping () -> Void) -> ClickRow {
        let btn = ClickRow(radius: z(4))
        btn.hoverColor = .hexA(UInt32(fg.toHex()), 0.30)
        btn.cursor = .pointingHand
        btn.toolTip = "Remove"
        btn.onClick = onRemove
        btn.frame = NSRect(x: x, y: (h - z(14)) / 2, width: w, height: z(14))
        let glyph = label("✕", sys(9), fg, align: .center)
        glyph.frame = NSRect(x: 0, y: z(1), width: w, height: z(12)); btn.addSubview(glyph)
        return btn
    }

    /// The compact "＋" picker-opener placed right after a metadata caption (LABELS/ASSIGNEES/
    /// REVIEWERS), styled in the accent like a subtle add affordance; highlighted while its picker is
    /// open. `tooltip` names what it adds, since the glyph alone carries no label text.
    private func pickerButton(_ title: String, t: Theme, on: Bool, tooltip: String? = nil,
                              onClick: @escaping () -> Void) -> NSView {
        let side = z(18)
        let btn = ClickRow(bg: on ? t.accentbg : t.accentbg2, radius: side / 2)
        btn.layer?.borderWidth = 1; btn.layer?.borderColor = t.accent.withAlphaComponent(0.4).cgColor
        btn.hoverColor = t.accentbg
        btn.cursor = .pointingHand
        btn.toolTip = tooltip
        btn.frame = NSRect(x: 0, y: 0, width: side, height: side)
        let lbl = label(title, sys(11, .semibold), t.accent, align: .center)
        lbl.frame = NSRect(x: 0, y: z(2), width: side, height: z(13)); btn.addSubview(lbl)
        btn.onClick = onClick
        return btn
    }

    /// The label picker overlay: a checklist of the repo's labels (✓ on the applied ones), each row a
    /// color dot + name; toggling saves immediately. Empty when the repo defines no labels (or the
    /// fetch is still in flight / failed).
    private func makeLabelMenu(t: Theme, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        makeChecklistMenu(t: t, x: x, y: y, width: width, empty: "No labels to choose",
                          rows: labelChoices.map { choice in
            ChecklistRow(title: choice.name, tint: choice.color, on: editLabels.contains(choice.name),
                         action: { [weak self] in self?.toggleLabel(choice.name) })
        })
    }

    /// The assignee picker overlay: a checklist of the repo's assignable users (✓ on the assigned ones).
    private func makeAssigneeMenu(t: Theme, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        makeChecklistMenu(t: t, x: x, y: y, width: width, empty: "No assignable users",
                          rows: assigneeChoices.map { choice in
            ChecklistRow(title: choice.login, tint: nil, on: editAssignees.contains(choice.login),
                         action: { [weak self] in self?.toggleAssignee(choice.login) })
        })
    }

    /// The reviewer picker overlay (issue #70): a checklist of the repo's assignable users (the same
    /// candidate pool as the assignee picker), ✓ on those with a *pending* request — toggling one
    /// requests a review or cancels the pending request.
    private func makeReviewerMenu(t: Theme, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let pending = Set((store.selectedItem?.reviewers ?? []).filter(\.isPending).map(\.login))
        return makeChecklistMenu(t: t, x: x, y: y, width: width, empty: "No assignable reviewers",
                                 rows: assigneeChoices.map { choice in
            ChecklistRow(title: choice.login, tint: nil, on: pending.contains(choice.login),
                         action: { [weak self] in self?.toggleReviewer(choice.login) })
        })
    }

    /// One row of a checklist picker.
    private struct ChecklistRow { let title: String; let tint: NSColor?; let on: Bool; let action: () -> Void }

    /// A floating multi-select checklist (mirrors `makeMergeMethodMenu`, but scrollable and with a ✓ on
    /// each selected row) returned for the caller to float over later content. Caps its height and
    /// scrolls when the list is long, so a repo with many labels/users doesn't run off the pane.
    private func makeChecklistMenu(t: Theme, x: CGFloat, y: CGFloat, width: CGFloat,
                                   empty: String, rows: [ChecklistRow]) -> NSView {
        let rowH = z(30), maxVisible: CGFloat = 7
        let contentH = rowH * CGFloat(max(rows.count, 1)) + z(10)
        let menuH = min(contentH, rowH * maxVisible + z(10))
        let menu = BoxView(bg: t.panel, radius: z(10), border: t.line2)
        menu.frame = NSRect(x: x, y: y, width: width, height: menuH)
        menu.layer?.shadowColor = NSColor.black.cgColor
        menu.layer?.shadowOpacity = 0.45; menu.layer?.shadowRadius = z(10); menu.layer?.shadowOffset = .zero

        let scroll = NSScrollView(frame: NSRect(x: 0, y: z(5), width: width, height: menuH - z(10)))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let docV = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: contentH - z(10)))
        if rows.isEmpty {
            let e = label(empty, sys(11.5), t.txt4)
            e.frame = NSRect(x: z(14), y: z(8), width: width - z(20), height: z(16)); docV.addSubview(e)
        }
        var my: CGFloat = 0
        for r in rows {
            let row = ClickRow(bg: r.on ? t.accentbg : nil, radius: z(7))
            row.hoverColor = t.hover
            row.frame = NSRect(x: z(5), y: my, width: width - z(12), height: rowH)
            let chk = label(r.on ? "✓" : "", sys(11), t.accent)
            chk.frame = NSRect(x: z(8), y: z(7), width: z(14), height: z(16)); row.addSubview(chk)
            var tx = z(26)
            if let tint = r.tint {
                let dot = BoxView(bg: tint, radius: z(5))
                dot.frame = NSRect(x: tx, y: z(10), width: z(10), height: z(10)); row.addSubview(dot); tx += z(16)
            }
            let ml = label(r.title, sys(12), t.txt)
            ml.frame = NSRect(x: tx, y: z(7), width: width - tx - z(12), height: z(16)); row.addSubview(ml)
            row.onClick = r.action
            docV.addSubview(row); my += rowH
        }
        scroll.documentView = docV
        menu.addSubview(scroll)
        return menu
    }

    // MARK: Merge section (PR-only)

    /// Lay out the merge control for an open PR into `doc` starting at `y`, returning the new `y`.
    /// `PRMergePolicy` decides whether to show the split-button (mergeable) or a disabled bar with a
    /// reason (draft/conflicts/blocked/checking). The editable commit fields show for the methods
    /// that create a commit; a rebase hides them (GitHub ignores commit text there).
    private func layoutMergeSection(for it: Item, into doc: NSView, t: Theme,
                                    padX: CGFloat, cw: CGFloat, y startY: CGFloat) -> CGFloat {
        var y = startY
        let availability = PRMergePolicy.availability(
            kind: .pullRequest, state: it.state,
            mergeable: it.mergeable, mergeStateStatus: it.mergeStateStatus)

        // Caption, mirroring the ACTIONS/FILES CHANGED/COMMENTS section captions. The merge
        // destination isn't named here — it rides the head → base branch chip up by the title.
        let hdr = label("MERGE", mono(9.5, .semibold), t.txt4)
        hdr.frame = NSRect(x: padX, y: y, width: cw, height: z(14)); doc.addSubview(hdr)
        y += z(22)

        // The collapsed "Close pull request" button shares the merge action row, right-aligned. Once
        // the close form is expanded (or a close is in flight) it renders below the row instead, so the
        // button is dropped from the row here.
        let canOfferClose = PRClosePolicy.canClose(kind: .pullRequest, state: it.state)
            && !closeConfirming && !isClosing
        let closeBtnW = z(150)

        if case let .blocked(reason) = availability {
            let barH = z(34)
            let barW = canOfferClose ? cw - closeBtnW - z(10) : cw
            let bar = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
            bar.frame = NSRect(x: padX, y: y, width: barW, height: barH)
            let glyph = label("⊘", sys(12), t.txt4, align: .center)
            glyph.frame = NSRect(x: z(12), y: z(9), width: z(16), height: z(16)); bar.addSubview(glyph)
            let msg = label(reason, sys(12), t.txt4)
            msg.frame = NSRect(x: z(34), y: z(9), width: barW - z(46), height: z(16)); bar.addSubview(msg)
            doc.addSubview(bar)
            if canOfferClose { doc.addSubview(makeCloseRowButton(t: t, x: padX + cw - closeBtnW, y: y, width: closeBtnW)) }
            return y + barH + z(18)
        }

        // Mergeable. Collapsed (GitHub default), the section is just the merge button; clicking it
        // expands the inline confirm form (commit fields + Confirm/Cancel). No commit fields show
        // until then — exactly like github.com.
        let barH = z(34), btnW = z(200)
        if isMerging {
            let spinner = makeSpinner(size: z(16))
            spinner.frame.origin = NSPoint(x: padX + z(4), y: y + z(8)); doc.addSubview(spinner)
            let lbl = label("Merging…", sys(12.5, .semibold), t.txt3)
            lbl.frame = NSRect(x: padX + z(28), y: y + z(8), width: cw - z(40), height: z(18)); doc.addSubview(lbl)
            y += barH + z(8)
        } else if mergeConfirming {
            // The editable commit fields (merge/squash only — rebase makes no commit), then the
            // inline Confirm/Cancel that replaces the old modal alert.
            if mergeMethod.usesCommitMessage {
                let titleBox = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
                titleBox.frame = NSRect(x: padX, y: y, width: cw, height: z(32))
                let tf = NSTextField(string: mergeTitleDraft)
                tf.font = sys(12.5); tf.placeholderString = "Commit title"
                tf.isBezeled = false; tf.drawsBackground = false; tf.focusRingType = .none
                tf.textColor = t.txt; tf.lineBreakMode = .byTruncatingTail
                tf.delegate = self
                tf.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
                tf.frame = NSRect(x: z(12), y: z(7), width: cw - z(24), height: z(18))
                titleBox.addSubview(tf); mergeTitleField = tf
                doc.addSubview(titleBox); y += z(40)

                // The commit message grows with its content (no inner scrollbar) so the whole body
                // stays visible no matter how many lines; `textDidChange` relayouts when a line is
                // added/removed. `lineFragmentPadding` is zeroed so the measured width matches.
                let textW = cw - z(20)
                let contentH = max(z(46), Self.textHeight(mergeBodyDraft, width: textW, font: sys(12.5)))
                mergeBodyContentH = contentH
                let msgH = contentH + z(20)
                let msgBox = BoxView(bg: t.card, radius: z(8), border: t.cardbr)
                msgBox.frame = NSRect(x: padX, y: y, width: cw, height: msgH)
                let tv = NSTextView(frame: NSRect(x: z(8), y: z(7), width: cw - z(16), height: msgH - z(14)))
                tv.string = mergeBodyDraft
                tv.font = sys(12.5); tv.textColor = t.txt
                tv.drawsBackground = false
                tv.isRichText = false
                tv.delegate = self
                tv.textContainerInset = NSSize(width: z(2), height: z(2))
                tv.textContainer?.lineFragmentPadding = 0
                tv.appearance = NSAppearance(named: t.key == "light" ? .aqua : .darkAqua)
                msgBox.addSubview(tv); mergeBodyField = tv
                doc.addSubview(msgBox); y += msgH + z(10)
            } else {
                mergeTitleField = nil; mergeBodyField = nil
            }

            let confirmW = z(126), cancelW = z(86), gap = z(8)
            let confirm = ClickRow(bg: t.accent, radius: z(8))
            confirm.frame = NSRect(x: padX, y: y, width: confirmW, height: barH)
            confirm.onClick = { [weak self] in self?.performMerge() }
            let cl = label("Confirm merge", sys(12, .semibold), t.onacc, align: .center)
            cl.frame = NSRect(x: 0, y: z(9), width: confirmW, height: z(16)); confirm.addSubview(cl)
            doc.addSubview(confirm)

            let cancel = ClickRow(bg: t.card, radius: z(8))
            cancel.layer?.borderWidth = 1; cancel.layer?.borderColor = t.cardbr.cgColor
            cancel.frame = NSRect(x: padX + confirmW + gap, y: y, width: cancelW, height: barH)
            cancel.onClick = { [weak self] in self?.cancelMergeConfirm() }
            let cancl = label("Cancel", sys(12, .semibold), t.txt2, align: .center)
            cancl.frame = NSRect(x: 0, y: z(9), width: cancelW, height: z(16)); cancel.addSubview(cancl)
            doc.addSubview(cancel)
            y += barH + z(8)
        } else {
            // Collapsed: just the split-button (primary opens the confirm form, caret opens the
            // method picker) with the mergeability status to its right. No commit fields yet.
            mergeTitleField = nil; mergeBodyField = nil
            let caretW = z(32), gap = z(5)
            let primaryW = btnW - caretW - gap
            let primary = ClickRow(bg: t.accent, radius: z(8))
            primary.frame = NSRect(x: padX, y: y, width: primaryW, height: barH)
            primary.onClick = { [weak self] in self?.beginMergeConfirm() }
            let pl = label(mergeMethod.buttonTitle, sys(12, .semibold), t.onacc, align: .center)
            pl.frame = NSRect(x: 0, y: z(9), width: primaryW, height: z(16)); primary.addSubview(pl)
            doc.addSubview(primary)

            let caret = ClickRow(bg: t.accent, radius: z(8))
            caret.frame = NSRect(x: padX + btnW - caretW, y: y, width: caretW, height: barH)
            caret.onClick = { [weak self] in self?.toggleMergeMenu() }
            let cl = label(mergeMenuOpen ? "▴" : "▾", sys(11), t.onacc, align: .center)
            cl.frame = NSRect(x: 0, y: z(9), width: caretW, height: z(16)); caret.addSubview(cl)
            doc.addSubview(caret)

            // Right-aligned Close button on the same row (GitHub keeps close beside merge).
            if canOfferClose {
                doc.addSubview(makeCloseRowButton(t: t, x: padX + cw - closeBtnW, y: y, width: closeBtnW))
            }

            let statusX = padX + btnW + z(14)
            let check = label("✓", sys(12, .bold), Status.green, align: .center)
            check.frame = NSRect(x: statusX, y: y + z(9), width: z(14), height: z(16)); doc.addSubview(check)
            // Status sits between the merge button and the (right-aligned) close button; bound its
            // width to the close button's left edge so the two never overlap on a narrow pane.
            let statusRight = canOfferClose ? padX + cw - closeBtnW - z(12) : padX + cw
            let statusW = max(z(20), statusRight - (statusX + z(20)))
            let statusLbl = label("No conflicts with base branch", sys(12), t.txt3)
            statusLbl.frame = NSRect(x: statusX + z(20), y: y + z(9), width: statusW, height: z(16))
            doc.addSubview(statusLbl)

            // Method picker: built at the button's bottom but added to `doc` last (in `rebuild()`) so
            // it floats over the comments below instead of pushing them down. Not counted into `y`.
            if mergeMenuOpen {
                mergeMenuOverlay = makeMergeMethodMenu(t: t, x: padX, y: y + barH + z(2), width: btnW)
            }
            y += barH + z(8)
        }

        if let mergeError {
            let err = label(mergeError, sys(11), Status.red, lines: 0)
            err.preferredMaxLayoutWidth = cw
            err.frame = NSRect(x: padX, y: y, width: cw, height: z(32))
            doc.addSubview(err); y += z(36)
        }
        return y + z(10)
    }

    /// The collapsed, bordered "Close pull request" button that shares the merge action row (placed
    /// right-aligned by the caller). Clicking it expands the inline close-confirm form below via
    /// `beginCloseConfirm`. Subordinate (bordered) styling so it doesn't rival the merge CTA.
    private func makeCloseRowButton(t: Theme, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let btn = ClickRow(bg: t.card, radius: z(8))
        btn.layer?.borderWidth = 1; btn.layer?.borderColor = t.cardbr.cgColor
        btn.frame = NSRect(x: x, y: y, width: width, height: z(34))
        btn.onClick = { [weak self] in self?.beginCloseConfirm() }
        let bl = label("Close pull request", sys(12, .semibold), t.txt2, align: .center)
        bl.frame = NSRect(x: 0, y: z(9), width: width, height: z(16)); btn.addSubview(bl)
        return btn
    }

    /// Lay out the *expanded* close-confirm form below the merge action row (the collapsed trigger is
    /// the right-aligned button on that row — see `makeCloseRowButton`). Only called while the close
    /// form is open or a close is in flight: a "Delete branch" checkbox (only when
    /// `PRClosePolicy.branchDeletable`, so a fork PR's branch — which can't be deleted from here — isn't
    /// offered), then Confirm/Cancel. Same no-modal pattern as the merge confirm; red confirm text as a
    /// caution cue.
    private func layoutCloseSection(for it: Item, into doc: NSView, t: Theme,
                                    padX: CGFloat, cw: CGFloat, y startY: CGFloat) -> CGFloat {
        var y = startY
        let barH = z(34)
        if isClosing {
            let spinner = makeSpinner(size: z(16))
            spinner.frame.origin = NSPoint(x: padX + z(4), y: y + z(8)); doc.addSubview(spinner)
            let lbl = label("Closing…", sys(12.5, .semibold), t.txt3)
            lbl.frame = NSRect(x: padX + z(28), y: y + z(8), width: cw - z(40), height: z(18)); doc.addSubview(lbl)
            y += barH + z(8)
        } else {
            // The delete-branch checkbox — shown only when the head branch is deletable (same-repo,
            // not the base). A fork PR (or the base branch) gets a plain close with no checkbox.
            if PRClosePolicy.branchDeletable(branch: it.branch, baseRefName: it.baseRef,
                                             isCrossRepository: it.isCrossRepository),
               let branch = it.branch {
                let row = ClickRow(bg: nil, radius: z(6))
                row.frame = NSRect(x: padX, y: y, width: cw, height: z(24))
                row.onClick = { [weak self] in self?.toggleDeleteBranch() }
                let box = label(deleteBranchChecked ? "☑" : "☐", sys(13), t.txt2)
                box.frame = NSRect(x: 0, y: z(3), width: z(18), height: z(18)); row.addSubview(box)
                let lbl = label("Delete branch \(branch) after closing", sys(12), t.txt2)
                lbl.frame = NSRect(x: z(22), y: z(4), width: cw - z(24), height: z(16)); row.addSubview(lbl)
                doc.addSubview(row); y += z(30)
            }

            let confirmW = z(150), cancelW = z(86), gap = z(8)
            // Filled-neutral confirm with red *text* — a caution cue for the (reversible) close plus a
            // possible branch delete, without an alarming red fill.
            let confirm = ClickRow(bg: t.card, radius: z(8))
            confirm.layer?.borderWidth = 1; confirm.layer?.borderColor = t.cardbr.cgColor
            confirm.frame = NSRect(x: padX, y: y, width: confirmW, height: barH)
            confirm.onClick = { [weak self] in self?.performClose() }
            let cl = label("Close pull request", sys(12, .semibold), Status.red, align: .center)
            cl.frame = NSRect(x: 0, y: z(9), width: confirmW, height: z(16)); confirm.addSubview(cl)
            doc.addSubview(confirm)

            let cancel = ClickRow(bg: t.card, radius: z(8))
            cancel.layer?.borderWidth = 1; cancel.layer?.borderColor = t.cardbr.cgColor
            cancel.frame = NSRect(x: padX + confirmW + gap, y: y, width: cancelW, height: barH)
            cancel.onClick = { [weak self] in self?.cancelCloseConfirm() }
            let cancl = label("Cancel", sys(12, .semibold), t.txt2, align: .center)
            cancl.frame = NSRect(x: 0, y: z(9), width: cancelW, height: z(16)); cancel.addSubview(cancl)
            doc.addSubview(cancel)
            y += barH + z(8)
        }

        if let closeError {
            let err = label(closeError, sys(11), Status.red, lines: 0)
            err.preferredMaxLayoutWidth = cw
            err.frame = NSRect(x: padX, y: y, width: cw, height: z(32))
            doc.addSubview(err); y += z(36)
        }
        return y + z(10)
    }

    /// Build the method-picker overlay (merge commit / squash / rebase, ✓ on the selected). Returned
    /// rather than added so the caller can float it over later content; mirrors the RepoPanelView menus.
    private func makeMergeMethodMenu(t: Theme, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let rowH = z(34)
        let menuH = rowH * CGFloat(PRMergeMethod.allCases.count) + z(10)
        let menu = BoxView(bg: t.panel, radius: z(10), border: t.line2)
        menu.frame = NSRect(x: x, y: y, width: width, height: menuH)
        menu.layer?.shadowColor = NSColor.black.cgColor
        menu.layer?.shadowOpacity = 0.45
        menu.layer?.shadowRadius = z(10)
        menu.layer?.shadowOffset = .zero
        var my = z(5)
        for m in PRMergeMethod.allCases {
            let on = m == mergeMethod
            let row = ClickRow(bg: on ? t.accentbg : nil, radius: z(7))
            row.hoverColor = t.hover
            row.frame = NSRect(x: z(5), y: my, width: width - z(10), height: rowH)
            let chk = label(on ? "✓" : "", sys(11), t.accent)
            chk.frame = NSRect(x: z(10), y: z(9), width: z(14), height: z(16)); row.addSubview(chk)
            let ml = label(m.title, sys(12), t.txt)
            ml.frame = NSRect(x: z(28), y: z(9), width: width - z(38), height: z(16)); row.addSubview(ml)
            row.onClick = { [weak self] in self?.selectMergeMethod(m) }
            menu.addSubview(row); my += rowH
        }
        return menu
    }

    /// Toggle the method picker open/closed.
    private func toggleMergeMenu() { mergeMenuOpen.toggle(); needsLayout = true }

    /// Pick a merge method, close the picker, and relayout (rebase hides the commit fields).
    private func selectMergeMethod(_ method: PRMergeMethod) {
        mergeMethod = method
        mergeMenuOpen = false
        needsLayout = true
    }

    /// GitHub's default merge-commit title: "Merge pull request #N from owner/branch" (falling back
    /// to just the number when the head branch/owner isn't known).
    private static func defaultMergeTitle(for it: Item) -> String {
        if let owner = it.ownerRepo?.owner, let branch = it.branch, !branch.isEmpty {
            return "Merge pull request #\(it.number) from \(owner)/\(branch)"
        }
        return "Merge pull request #\(it.number)"
    }

    /// The height `text` needs when wrapped to `width` in `font` — drives the elastic commit-message
    /// field. Measures a single space for empty text so the field keeps a one-line minimum.
    private static func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let measured = (text.isEmpty ? " " : text) as NSString
        let rect = measured.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return ceil(rect.height)
    }

    /// Expand the inline confirm form (GitHub-style) where the user reviews/edits the commit text
    /// before merging. No modal — the form's Confirm merge button is the confirmation.
    private func beginMergeConfirm() {
        guard !isMerging else { return }
        mergeConfirming = true
        mergeMenuOpen = false
        mergeError = nil
        needsLayout = true
    }

    /// Collapse the confirm form without merging.
    private func cancelMergeConfirm() {
        mergeConfirming = false
        mergeError = nil
        needsLayout = true
    }

    /// Merge the open PR with the chosen method + edited commit text — the confirm form's action.
    /// No-ops while a merge is in flight. Captures the latest field values, flips to the in-flight
    /// state, and hands a `PRMergeRequest` to the controller via `onMergePullRequest`, which calls
    /// back to collapse the form on success or surface the error (keeping the form) on failure.
    private func performMerge() {
        guard !isMerging, let onMergePullRequest else { return }
        let title = mergeTitleField?.stringValue ?? mergeTitleDraft
        let body = mergeBodyField?.string ?? mergeBodyDraft
        mergeTitleDraft = title; mergeBodyDraft = body
        mergeError = nil
        isMerging = true
        needsLayout = true
        let request = PRMergeRequest(method: mergeMethod, commitTitle: title, commitMessage: body)
        onMergePullRequest(request) { [weak self] ok, message in
            guard let self else { return }
            self.isMerging = false
            if ok {
                self.mergeError = nil
                self.mergeConfirming = false   // the controller refreshes to `merged`, hiding the section
            } else if let message {
                self.mergeError = message       // keep the form open so the user can retry
            }
            self.needsLayout = true
        }
    }

    /// Expand the inline confirm form for closing the PR. No modal — the form's Close button confirms.
    private func beginCloseConfirm() {
        guard !isClosing else { return }
        closeConfirming = true
        closeError = nil
        needsLayout = true
    }

    /// Collapse the confirm form without closing.
    private func cancelCloseConfirm() {
        closeConfirming = false
        closeError = nil
        needsLayout = true
    }

    /// Toggle whether closing also deletes the head branch.
    private func toggleDeleteBranch() { deleteBranchChecked.toggle(); needsLayout = true }

    /// Close the open PR (and, if the checkbox is on, delete its head branch) — the confirm form's
    /// action. No-ops while a close is in flight. Flips to the in-flight state and hands the choice to
    /// the controller via `onClosePullRequest`, which calls back to collapse on success (the controller
    /// refreshes to `closed`, hiding the section) or surface the error (keeping the form) on failure.
    private func performClose() {
        guard !isClosing, let onClosePullRequest else { return }
        closeError = nil
        isClosing = true
        needsLayout = true
        onClosePullRequest(deleteBranchChecked) { [weak self] ok, message in
            guard let self else { return }
            self.isClosing = false
            if ok {
                self.closeError = nil
                self.closeConfirming = false
            } else if let message {
                self.closeError = message
            }
            self.needsLayout = true
        }
    }

    /// Post the current composer text. Shared by the Send button and the Return key. No-ops while a
    /// post is in flight or the body is blank; otherwise flips to the posting state and hands the
    /// text to the controller via `onSubmitComment`, which calls back to clear or restore the draft.
    private func submitComposer() {
        guard !isPosting, let onSubmitComment else { return }
        let text = composerField?.stringValue ?? composerDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composerDraft = text
        composerError = nil
        isPosting = true
        needsLayout = true
        onSubmitComment(text) { [weak self] ok, message in
            guard let self else { return }
            self.isPosting = false
            if ok {
                self.composerDraft = ""
                self.composerError = nil
            } else if let message {
                self.composerError = message   // keep the draft so the user can retry
            }
            self.needsLayout = true
        }
    }

    @objc private func composerReturn() { submitComposer() }

    /// A reason-dropdown pick now only *selects* the reason and re-labels the primary button — it does
    /// NOT close. Closing happens when the user presses the (re-labelled) primary button. Leaving the
    /// duplicate reason clears the parent picker so a stale parent can't ride a later close.
    @objc private func closeIssueMenuAction(_ sender: NSMenuItem) {
        let reasons: [IssueCloseReason] = [.completed, .notPlanned, .duplicate]
        guard sender.tag < reasons.count else { return }
        selectedCloseReason = reasons[sender.tag]
        if selectedCloseReason != .duplicate {
            duplicateParentNumber = nil; duplicateParentTitle = nil
            duplicateQuery = ""; duplicateResults = []; duplicateMenuOpen = false
            dupSearchWork?.cancel()
        }
        needsLayout = true
    }

    /// Close the issue with the currently-selected reason (fired by the primary button). Threads the
    /// duplicate parent number so a duplicate close posts the `Duplicate of #N` marker; guards against a
    /// duplicate close with no parent (the button is disabled then, but belt-and-suspenders).
    private func submitCurrentClose() {
        guard !isClosingIssue, let onCloseIssue else { return }
        if selectedCloseReason == .duplicate && duplicateParentNumber == nil { return }
        isClosingIssue = true; closeIssueError = nil; needsLayout = true
        onCloseIssue(selectedCloseReason, duplicateParentNumber) { [weak self] ok, message in
            guard let self else { return }
            self.isClosingIssue = false
            if !ok { self.closeIssueError = message }
            self.needsLayout = true
        }
    }

    /// Open the selected item's GitHub page in the default browser. Wired to the `#num` anchor link
    /// in the id row.
    private func openItemURL(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Copy a fenced code block's text to the clipboard and briefly swap its button glyph to a
    /// checkmark. Mutates the button icon in place (no relayout), so the confirmation flash isn't lost
    /// to the rebuild a `needsLayout` would trigger; an unrelated rebuild within the window just resets
    /// it early, which is fine for a transient cue.
    private func copyCode(_ code: String, icon: NSImageView) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        icon.contentTintColor = store.theme.accent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak icon] in
            guard let self, let icon else { return }
            icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
            icon.contentTintColor = self.store.theme.txt4
        }
    }

    /// Copy the selected item's web URL to the clipboard and flash a transient "Copied ✓" in the id
    /// row. Mirrors `DeviceFlowSheet.copyCode`: set the flag, relayout to show it, and revert shortly
    /// after unless another copy has moved the state on.
    private func copyItemURL(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        justCopiedURL = true
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.justCopiedURL else { return }
            self.justCopiedURL = false
            self.needsLayout = true
        }
    }
}

extension DetailView: NSTextFieldDelegate {
    /// Keep the persisted draft in sync as the user types, so a rebuild (resize, theme, a comment
    /// landing) preserves the in-progress text instead of resetting the field. Handles both the
    /// comment composer and the merge commit-title field.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === composerField { composerDraft = field.stringValue }
        else if field === mergeTitleField { mergeTitleDraft = field.stringValue }
        else if field === editTitleField { editTitleDraft = field.stringValue }
        else if field === duplicateSearchField {
            // Debounce the duplicate-parent search so a fast typist doesn't hammer GitHub's rate-limited
            // search API; only the last keystroke in a 250ms window fires. Stale results (query moved on)
            // are dropped in the completion. No relayout on the keystroke itself — the field keeps focus;
            // the results overlay refreshes when the search returns.
            duplicateQuery = field.stringValue
            dupSearchWork?.cancel()
            let q = duplicateQuery
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.duplicateQuery == q else { return }
                self.onSearchIssues?(q) { [weak self] results in
                    guard let self, self.duplicateQuery == q else { return }
                    self.duplicateResults = results
                    self.duplicateMenuOpen = !q.trimmingCharacters(in: .whitespaces).isEmpty
                    self.needsLayout = true
                }
            }
            dupSearchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

extension DetailView: NSTextViewDelegate {
    /// Keep the merge commit-message draft in sync as the user types (same survives-`rebuild()`
    /// reason as the title field above), and relayout when the field needs to grow or shrink by a
    /// line so it stays elastic. Only a height change triggers a rebuild — typing within a line
    /// doesn't churn the layout — and `rebuild()` restores focus + caret so typing isn't interrupted.
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        let cw = bounds.width - z(26) * 2   // the content width `rebuild()` lays out against
        if tv === mergeBodyField {
            mergeBodyDraft = tv.string
            let newH = max(z(46), Self.textHeight(mergeBodyDraft, width: cw - z(20), font: sys(12.5)))
            if abs(newH - mergeBodyContentH) > 0.5 { needsLayout = true }
        } else if tv === editBodyField {
            editBodyDraft = tv.string
            // Matches the edit-body field's measured width in `rebuild()`: (cw − z(20)) inner − z(8).
            let newH = max(z(140), Self.textHeight(editBodyDraft, width: cw - z(20) - z(8), font: sys(13.5)))
            if abs(newH - editBodyContentH) > 0.5 { needsLayout = true }
        }
    }
}

extension NSColor {
    /// Best-effort RGB hex (used to re-tint check icons).
    func toHex() -> Int {
        guard let c = usingColorSpace(.sRGB) else { return 0x6b7079 }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return (r << 16) | (g << 8) | b
    }
}
