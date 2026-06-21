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

        guard let cfg = ghostty_config_new() else {
            NSLog("ghostty_config_new failed")
            availability = .unavailable(.configuration)
            return
        }
        ghostty_config_load_default_files(cfg)

        // Override the terminal palette to match the mock's docked terminal: a near-black
        // (#0a0c0f) body with periwinkle prompt/cursor and JetBrains Mono (the font the
        // design uses; ghostty falls back gracefully if it isn't installed). Loaded after
        // the user's default files so these win, before finalize.
        let overrides = """
        background = 0a0c0f
        foreground = c2c6cd
        cursor-color = 7c8cff
        cursor-style = block
        font-family = JetBrains Mono
        """
        let confURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-workbench.ghostty.conf")
        if (try? overrides.write(to: confURL, atomically: true, encoding: .utf8)) != nil {
            confURL.path.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_finalize(cfg)
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
            action_cb: { _, _, _ in
                // The demo does not act on app actions (set-title, bell, etc.).
                return false
            },
            read_clipboard_cb: { userdata, _, state in
                guard let userdata else { return false }
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return false }
                guard let str = NSPasteboard.general.string(forType: .string) else { return false }
                str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
                return true
            },
            confirm_read_clipboard_cb: { _, _, _, _ in },
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
            close_surface_cb: { _, _ in }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("ghostty_app_new failed")
            availability = .unavailable(.application)
            return
        }
        self.app = app
        ghostty_app_set_focus(app, true)
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
