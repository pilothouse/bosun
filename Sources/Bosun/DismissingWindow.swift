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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onMouseDown?(event.locationInWindow)
        }
        super.sendEvent(event)
    }
}
