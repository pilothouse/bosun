import AppKit
import CGhostty

// libghostty global init must happen before any app/surface is created.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fatalError("ghostty_init failed")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
