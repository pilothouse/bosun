import AppKit
import CGhostty
import Domain

/// Runs `body` with a C-string pointer for `string` (or nil when it's nil), keeping the backing
/// buffer alive for the duration of the call.
private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

/// A layer-backed NSView that hosts a single libghostty terminal surface.
/// libghostty creates and drives its own `CAMetalLayer` on this view given the
/// nsview pointer; we forward size, scale, focus, mouse and keyboard events.
final class GhosttySurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?

    /// Invoked when libghostty asks to close this surface (e.g. the shell exited). The owner
    /// (the terminal dock) decides what closing means — it removes this surface's tab.
    var onChildExit: ((_ processAlive: Bool) -> Void)?

    /// Invoked when the shell/OSC reports a new title; the dock uses it to label the tab.
    var onTitleChange: ((String) -> Void)?

    /// Native ghostty tab keybindings, surfaced for the dock to act on: open a new tab (⌘T),
    /// close this surface's tab, and jump to another tab (⌘1…9 / next / previous / last).
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onGotoTab: ((TabJump) -> Void)?

    /// Latest shell/OSC-reported title for this surface; the dock reads it to label the tab.
    private(set) var title: String?

    /// Whether this surface runs a connection command (an SSH tab) rather than a plain shell. Such a
    /// surface keeps ghostty's "Process exited. Press any key to close." screen when its process
    /// exits, so a failed or finished connection stays visible with its error instead of the tab
    /// vanishing; a plain shell (or local-folder shell) auto-closes its tab on exit. Read by the
    /// `SHOW_CHILD_EXITED` handler in `GhosttyApp`.
    let waitsOnExit: Bool

    /// Whether libghostty wants confirmation before this surface is torn down (a foreground
    /// child is still running). Used when the user closes a tab manually via its × button.
    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Tracks our balance against the process-global `NSCursor` hide stack so MOUSE_VISIBILITY
    /// can't leak a hidden cursor by hiding twice or unhiding when already visible.
    private var cursorHidden = false

    override var acceptsFirstResponder: Bool { true }

    /// `command`, when set, is the shell command line the surface runs instead of the default
    /// login shell (e.g. `ssh ubuntu@host` for a connection tab). `workingDirectory`, when set, is
    /// the directory the shell starts in (e.g. a local-folder connection's path).
    init(app: ghostty_app_t, command: String? = nil, workingDirectory: String? = nil) {
        self.waitsOnExit = (command != nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        focusRingType = .none

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        // A local shell auto-closes its tab the moment it exits (no wait screen) — a clean `exit`
        // shouldn't leave an empty tab behind. A connection command (an SSH tab) instead keeps
        // ghostty's "Process exited (N). Press any key to close." screen (see the SHOW_CHILD_EXITED
        // handler in GhosttyApp), so a connection that fails or dies immediately (a bad host/user)
        // stays open with its error visible rather than the tab vanishing before it can be read.
        cfg.wait_after_command = waitsOnExit

        // `cfg.command` / `cfg.working_directory` only need to stay valid for the duration of
        // ghostty_surface_new (it copies what it needs), so build the surface inside the C-strings'
        // lifetimes, nesting the optional ones.
        withOptionalCString(command) { cmd in
            if let cmd { cfg.command = cmd }
            withOptionalCString(workingDirectory) { dir in
                if let dir { cfg.working_directory = dir }
                self.surface = ghostty_surface_new(app, &cfg)
            }
        }
        if surface == nil { NSLog("ghostty_surface_new failed") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    /// Push a rebuilt config (e.g. a new theme palette) to this live surface so its colors update
    /// in place, without recreating the surface (issue #9). Repaints on the next app tick.
    func updateConfig(_ cfg: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, cfg)
    }

    /// Invoke a libghostty keybind action by name on *this* surface only — the path for the
    /// console-only font zoom (⌥⌘+ / ⌥⌘− / ⌥⌘0), which adjusts just the focused terminal on top of
    /// the global zoom baseline. `action` is one of the strings ghostty's binding parser accepts,
    /// e.g. `"increase_font_size:1"`, `"decrease_font_size:1"`, `"reset_font_size"`. Repaints on the
    /// next app tick.
    func runBindingAction(_ action: String) {
        guard let surface else { return }
        let ok = action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
        if !ok { NSLog("ghostty binding action failed: \(action)") }
        GhosttyApp.shared.tick()
    }

    deinit {
        if cursorHidden { NSCursor.unhide() }
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: Sizing / scale

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { layer?.contentsScale = window.backingScaleFactor }
        updateContentScale()
        updateSurfaceSize()
        if let surface, let window { ghostty_surface_set_focus(surface, window.isKeyWindow) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateContentScale()
        updateSurfaceSize()
    }

    private func updateContentScale() {
        guard let surface else { return }
        let fb = convertToBacking(bounds)
        let xs = bounds.width > 0 ? fb.width / bounds.width : 2
        let ys = bounds.height > 0 ? fb.height / bounds.height : 2
        ghostty_surface_set_content_scale(surface, Double(xs), Double(ys))
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scaled = convertToBacking(bounds)
        ghostty_surface_set_size(surface,
                                 UInt32(max(1, scaled.width)),
                                 UInt32(max(1, scaled.height)))
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    // MARK: Mouse

    private func mods(_ e: NSEvent) -> ghostty_input_mods_e { Self.ghosttyMods(e.modifierFlags) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if let s = surface { ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(e)) }
    }
    override func mouseUp(with e: NSEvent) {
        if let s = surface { ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(e)) }
    }
    override func rightMouseDown(with e: NSEvent) {
        if let s = surface { ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(e)) }
    }
    override func rightMouseUp(with e: NSEvent) {
        if let s = surface { ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(e)) }
    }
    override func mouseMoved(with e: NSEvent) { sendPos(e) }
    override func mouseDragged(with e: NSEvent) { sendPos(e) }
    override func rightMouseDragged(with e: NSEvent) { sendPos(e) }

    private func sendPos(_ e: NSEvent) {
        guard let s = surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, Double(p.x), Double(bounds.height - p.y), mods(e))
    }

    override func scrollWheel(with e: NSEvent) {
        guard let s = surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        ghostty_surface_mouse_scroll(s, Double(x), Double(y),
                                     ghostty_input_scroll_mods_t(precise ? 1 : 0))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        sendKey(e, action: e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }
    override func keyUp(with e: NSEvent) {
        sendKey(e, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKey(_ e: NSEvent, action: ghostty_input_action_e) {
        guard let s = surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(e.keyCode)
        key.mods = mods(e)
        key.consumed_mods = ghostty_input_mods_e(0)
        key.composing = false
        if let scalar = (e.charactersIgnoringModifiers ?? "").unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }

        // When control/command are held, libghostty derives the control sequence
        // from keycode+mods; passing text too would double-send. Otherwise pass
        // the literal typed text so printable input (incl. shifted/option) works.
        let hasCtrlCmd = e.modifierFlags.contains(.control) || e.modifierFlags.contains(.command)
        let text = (hasCtrlCmd ? "" : (e.characters ?? ""))

        if text.isEmpty {
            key.text = nil
            _ = ghostty_surface_key(s, key)
        } else {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(s, key)
            }
        }
    }

    // MARK: App actions & lifecycle

    /// SET_TITLE: store and notify the dock so it can relabel this surface's tab.
    func setTitle(_ s: String) {
        title = s
        onTitleChange?(s)
    }

    /// RING_BELL: audible beep, plus a Dock bounce when we're in the background.
    func ringBell() {
        NSSound.beep()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// MOUSE_SHAPE: map the shapes we have native cursors for; everything else falls back to arrow.
    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        cursor.set()
    }

    /// MOUSE_VISIBILITY: balanced against the global hide stack so we never leak a hidden cursor.
    func setMouseVisible(_ visible: Bool) {
        if visible {
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        } else if !cursorHidden {
            NSCursor.hide(); cursorHidden = true
        }
    }

    /// DESKTOP_NOTIFICATION: best-effort user notification. Uses the bundle-free (deprecated)
    /// `NSUserNotification` because this app runs as a bare `swift build` binary, not a `.app`
    /// bundle — `UNUserNotificationCenter` requires a bundle id and would trap here. Delivery is
    /// itself best-effort for an unbundled binary; the handler still reports the action as handled.
    func postNotification(title: String, body: String) {
        let note = NSUserNotification()
        note.title = title.isEmpty ? "Terminal" : title
        note.informativeText = body
        NSUserNotificationCenter.default.deliver(note)
    }

    /// Confirm an application's request to read/write the clipboard (OSC-52 or a guarded paste).
    /// Deferred off the current libghostty tick so the modal can't re-enter `ghostty_app_tick`;
    /// completes the request exactly once on every path so the clipboard state machine never stalls.
    func confirmRead(str: String, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let surface = self.surface else { return }
            let prompt: String
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                prompt = "Paste this text into the terminal?"
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
                prompt = "An application is trying to write to the clipboard."
            default:
                prompt = "An application is trying to read from the clipboard."
            }
            let alert = NSAlert()
            alert.messageText = prompt
            alert.informativeText = str
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            let confirmed = alert.runModal() == .alertFirstButtonReturn
            str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, confirmed) }
        }
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(m)
    }
}
