import AppKit
import CGhostty
import Domain

/// Owns the single `ghostty_app_t` for the process and the libghostty runtime
/// callbacks. Mirrors a trimmed version of Ghostty's own `Ghostty.App`.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    /// Whether the terminal subsystem came up, and if not, where it failed. Read by the App layer
    /// to render an error state instead of a dead surface (issue #16).
    private(set) var availability: TerminalAvailability = .ready

    /// Global libghostty init. Must run once, before any app/surface is created (i.e. before
    /// `start()`). A failure here is *not* fatal: it is recorded so the app can boot a usable
    /// shell and surface the error, rather than aborting the process.
    func initializeRuntime() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("ghostty_init failed")
            availability = .unavailable(.runtimeInit)
        }
    }

    /// Create the ghostty config + app. Call once after `initializeRuntime()`.
    func start() {
        // If the global runtime init failed, calling config/app creation is undefined — stay
        // failed and let the App layer render the error state.
        guard availability.isReady else { return }
        guard app == nil else { return }

        // Build the initial config from the default theme's terminal palette. The persisted theme
        // (which may differ) is applied live once it loads, via `applyPalette` (issue #9).
        guard let cfg = makeConfig(Theme.named("operator").terminalPalette) else {
            NSLog("ghostty_config_new failed")
            availability = .unavailable(.configuration)
            return
        }
        self.config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let me = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                // wakeup may be called from any thread; coalesce a tick onto main.
                DispatchQueue.main.async { me.tick() }
            },
            action_cb: { _, target, action in
                // Only surface-targeted actions are actionable here; resolve the owning view via
                // the surface's userdata (the same handle `read_clipboard_cb` below relies on).
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let ud = ghostty_surface_userdata(target.target.surface) else { return false }
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
                switch action.tag {
                case GHOSTTY_ACTION_SET_TITLE:
                    if let c = action.action.set_title.title { view.setTitle(String(cString: c)) }
                    return true
                case GHOSTTY_ACTION_RING_BELL:
                    view.ringBell()
                    return true
                case GHOSTTY_ACTION_MOUSE_SHAPE:
                    view.setMouseShape(action.action.mouse_shape)
                    return true
                case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                    view.setMouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
                    return true
                case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                    let n = action.action.desktop_notification
                    view.postNotification(title: n.title.map { String(cString: $0) } ?? "",
                                          body: n.body.map { String(cString: $0) } ?? "")
                    return true
                case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                    // The child (shell or ssh) exited. A connection (SSH) tab returns false so
                    // ghostty renders its "Process exited. Press any key to close the terminal."
                    // screen (which it does precisely when this action goes unhandled) — a failed or
                    // finished connection stays visible with its error instead of the tab vanishing;
                    // the key press then closes it via close_surface_cb. A plain shell auto-closes
                    // its tab here (its `exit` is intentional); the process is already gone, so no
                    // close confirmation is needed.
                    if view.waitsOnExit { return false }
                    view.onChildExit?(false)
                    return true
                case GHOSTTY_ACTION_NEW_TAB:
                    view.onNewTab?()
                    return true
                case GHOSTTY_ACTION_CLOSE_TAB:
                    view.onCloseTab?()
                    return true
                case GHOSTTY_ACTION_GOTO_TAB:
                    // goto_tab encodes -1/-2/-3 as previous/next/last; any other value is a
                    // 1-based tab index (⌘1…9).
                    let raw = Int(action.action.goto_tab.rawValue)
                    let jump: TabJump
                    switch raw {
                    case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue): jump = .previous
                    case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue): jump = .next
                    case Int(GHOSTTY_GOTO_TAB_LAST.rawValue): jump = .last
                    default: jump = .index(raw)
                    }
                    view.onGotoTab?(jump)
                    return true
                default:
                    // Unhandled: return false so libghostty keeps its own default behavior.
                    return false
                }
            },
            read_clipboard_cb: { userdata, _, state in
                guard let userdata else { return false }
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return false }
                guard let str = NSPasteboard.general.string(forType: .string) else { return false }
                str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
                return true
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                // No surface (userdata) or payload → nothing to complete against; libghostty owns
                // that edge. Otherwise hand off to the view, which defers the modal off this tick.
                guard let userdata, let str else { return }
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                view.confirmRead(str: String(cString: str), state: state, request: request)
            },
            write_clipboard_cb: { _, _, content, len, _ in
                // Copy the first text payload out to the general pasteboard.
                guard let content, len > 0 else { return }
                let item = content.pointee
                if let dataPtr = item.data {
                    let s = String(cString: dataPtr)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
            },
            close_surface_cb: { userdata, processAlive in
                // Route to the owning view; it (via its owner) decides what closing means. Do not
                // free the surface here — `GhosttySurfaceView.deinit` already does, so the view tree
                // teardown handles it; freeing twice would be a double-free.
                guard let userdata else { return }
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                view.onChildExit?(processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("ghostty_app_new failed")
            availability = .unavailable(.application)
            return
        }
        self.app = app
        ghostty_app_set_focus(app, true)
    }

    /// Build a finalized ghostty config: load the user's default files, then override the terminal
    /// palette (from the active theme) and font so ours win. libghostty parses config from text, so
    /// the override is written to a temp file and loaded. Returns nil only if libghostty can't
    /// allocate a config.
    private func makeConfig(_ palette: TerminalPalette) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        // JetBrains Mono is the font the design uses; ghostty falls back gracefully if it isn't
        // installed. Loaded after the defaults so the theme palette wins, before finalize.
        let overrides = palette.ghosttyConfig(fontFamily: "JetBrains Mono", cursorStyle: "block")
        let confURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-workbench.ghostty.conf")
        if (try? overrides.write(to: confURL, atomically: true, encoding: .utf8)) != nil {
            confURL.path.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// Rebuild the config for a new terminal palette and push it to the running app, returning the
    /// finalized config so the dock can update its live surfaces too. The previous config is freed
    /// once the app has adopted the new one — libghostty copies what it needs (the same assumption
    /// `start()` relies on when the override text goes out of scope). No-op (nil) when the terminal
    /// never came up.
    func applyPalette(_ palette: TerminalPalette) -> ghostty_config_t? {
        guard let app, let cfg = makeConfig(palette) else { return nil }
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
        return cfg
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }
}
