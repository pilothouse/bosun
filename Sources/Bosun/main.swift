import AppKit

// libghostty global init must happen before any app/surface is created. A failure here is
// recorded (not fatal) so the app still boots a usable shell and surfaces the error in the
// terminal dock — see GhosttyApp.availability and issue #16.
GhosttyApp.shared.initializeRuntime()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
