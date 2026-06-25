import AppKit

/// The app window, with one extra job: tell the app about every mouse-down so an open custom
/// dropdown can dismiss on a click anywhere outside it. The dropdowns are plain overlay views (not
/// real `NSMenu`s), and this libghostty-hosted window doesn't deliver clicks to app-level
/// `NSEvent` monitors — but every click still flows through `sendEvent` on its way to a view, so
/// this is the one place that reliably sees all of them.
final class DismissingWindow: NSWindow {
    /// Called for each mouse-down with its location in window coordinates, before the event is
    /// dispatched to a view. Set by the composition root.
    var onMouseDown: ((NSPoint) -> Void)?

    /// Called when bare ⌘= is pressed. The "Zoom In" menu item carries ⌘+ (which needs Shift on US
    /// layouts), so the menu stays clean with a single shortcut; this catches the unshifted ⌘= — the
    /// same physical +/= key — so it zooms in too, without a duplicate menu entry. Set by the
    /// composition root.
    var onZoomIn: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onMouseDown?(event.locationInWindow)
        }
        super.sendEvent(event)
    }

    /// Intercept bare ⌘= before it reaches a view (e.g. the terminal) and route it to zoom-in — the
    /// keybinding kept for the +/= key without Shift. Every other key equivalent falls through to the
    /// normal view/menu dispatch via `super`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "=", let onZoomIn {
            onZoomIn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
