import AppKit
import CGhostty

/// A layer-backed NSView that hosts a single libghostty terminal surface.
/// libghostty creates and drives its own `CAMetalLayer` on this view given the
/// nsview pointer; we forward size, scale, focus, mouse and keyboard events.
final class GhosttySurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?

    override var acceptsFirstResponder: Bool { true }

    init(app: ghostty_app_t) {
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

        guard let s = ghostty_surface_new(app, &cfg) else {
            NSLog("ghostty_surface_new failed")
            return
        }
        self.surface = s
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    deinit {
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
