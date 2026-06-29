/// Pure geometry for the Settings window's resize-to-fit when switching panes (#88). The window keeps
/// its TOP edge fixed so the toolbar stays put while the body grows or shrinks to the selected pane —
/// mirroring System Settings (and NetNewsWire's preferences window). Framework-free: like `Preferences`
/// keeps opacity as `Double`, this stays clear of CoreGraphics and the App layer converts `Frame` ↔
/// `NSRect` at the boundary.
public enum SettingsPaneLayout {

    /// A rectangle in AppKit's bottom-left origin space, expressed in `Double` so Domain owns no
    /// CoreGraphics types. `maxY` is the window's top edge.
    public struct Frame: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var width: Double
        public var height: Double

        public init(minX: Double, minY: Double, width: Double, height: Double) {
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
        }

        /// The top edge (origin is bottom-left), held constant across a pane switch.
        public var maxY: Double { minY + height }
    }

    /// The window frame that shows a pane of `paneWidth` × `paneHeight`: the window adopts that size
    /// plus the constant `chromeHeight` (titlebar + toolbar), with its top edge pinned to
    /// `current.maxY` so the toolbar doesn't jump while the body resizes.
    public static func windowFrame(current: Frame,
                                   paneWidth: Double,
                                   paneHeight: Double,
                                   chromeHeight: Double) -> Frame {
        let height = paneHeight + chromeHeight
        let top = current.maxY
        return Frame(minX: current.minX, minY: top - height, width: paneWidth, height: height)
    }
}
