import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var root: WorkbenchView!
    let ghostty = GhosttyApp.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        ghostty.start()
        installMenu()

        let store = Store()
        let root = WorkbenchView(store: store, ghostty: ghostty)
        self.root = root

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1340, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "Workbench"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 1100, height: 720)
        win.contentView = root
        win.center()
        win.makeKeyAndOrderFront(nil)
        // Traffic lights sit over our custom titlebar; keep them in place.
        win.standardWindowButton(.closeButton)?.superview?.needsLayout = true

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { root.focusTerminal() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
