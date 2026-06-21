import AppKit
import Domain

/// Shown in the terminal dock when libghostty failed to come up (issue #16). Stands in for the
/// live surface so the rest of the app stays usable. Uses fixed dark-surface colors, not the
/// active theme: the terminal dock is always near-black (matching `TerminalContainerView`), so
/// theme text colors — light in the Daylight theme — could render invisible here.
final class TerminalUnavailableView: FlippedView {
    private let stage: TerminalStartupStage

    init(stage: TerminalStartupStage) {
        self.stage = stage
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        layer?.backgroundColor = NSColor.hex(0x0a0c0f).cgColor
        subviews.forEach { $0.removeFromSuperview() }

        let cw = min(w - 48, 440)               // content column, padded from the edges
        guard cw > 80, h > 90 else { return }   // too cramped to render legibly
        let cx = (w - cw) / 2

        // Icon (tintable SF Symbol, consistent with the titlebar's icon buttons).
        let iconH: CGFloat = 30
        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            img.isTemplate = true
            icon.image = img
            icon.contentTintColor = Status.yellow
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)
        }
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter

        let head = label(stage.headline, sys(14, .semibold), .hex(0xe6e8ec), align: .center)
        let headH: CGFloat = 20

        let detail = label(stage.detail, sys(12), .hex(0x9aa0aa), align: .center, lines: 3)
        let detailH = ceil((stage.detail as NSString).boundingRect(
            with: NSSize(width: cw, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: sys(12)]).height) + 2

        let gap1: CGFloat = 12, gap2: CGFloat = 8
        let blockH = iconH + gap1 + headH + gap2 + detailH
        var y = max(16, (h - blockH) / 2)

        icon.frame = NSRect(x: cx, y: y, width: cw, height: iconH); addSubview(icon); y += iconH + gap1
        head.frame = NSRect(x: cx, y: y, width: cw, height: headH); addSubview(head); y += headH + gap2
        detail.frame = NSRect(x: cx, y: y, width: cw, height: detailH); addSubview(detail)
    }
}

/// User-facing copy for each failure stage. Lives in the App layer (presentation), not Domain —
/// wording can change here without touching the `TerminalAvailability` contract.
private extension TerminalStartupStage {
    var headline: String { "Terminal unavailable" }

    var detail: String {
        let suffix = "The rest of bosun works normally. Check Console for details, then relaunch to retry."
        switch self {
        case .runtimeInit:
            return "The terminal engine couldn’t initialize. \(suffix)"
        case .configuration:
            return "The terminal configuration couldn’t be loaded. \(suffix)"
        case .application:
            return "The terminal engine failed to start. \(suffix)"
        }
    }
}
