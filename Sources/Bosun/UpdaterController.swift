import AppKit
import Domain
import Sparkle

/// Owns the Sparkle auto-updater and is the ONLY file in the app that imports Sparkle, so a future
/// Mac App Store build can drop the dependency behind this one seam. Sparkle is forbidden in App Store
/// apps (self-updating code violates the rules), so when the app runs from a `_MASReceipt` build the
/// updater is never created: `isAvailable` is false and AppDelegate/Settings hide the update affordances
/// (the rule itself lives in `Domain.UpdatePolicy`).
///
/// For every other build the updater starts at launch, reads `SUFeedURL` / `SUPublicEDKey` from the
/// Info.plist (written by scripts/package-app.sh), and on first launch asks whether to check
/// automatically. The feed is the signed appcast attached to the latest GitHub Release (issue #57).
final class UpdaterController: NSObject, NSMenuItemValidation {
    /// nil for an App Store build (no Sparkle). Otherwise a started `SPUStandardUpdaterController`,
    /// which wires up Sparkle's standard user-facing update UI and background scheduler.
    private let controller: SPUStandardUpdaterController?

    /// `enabled` is false in UI-test mode (`AppMode.uiTest`), so Sparkle never starts and its
    /// launch-time "unable to check for updates" alert can't steal focus from a scripted UI run —
    /// the same reason the mode bypasses the Keychain. The caller decides (see `AppDelegate`), keeping
    /// this controller unaware of the app's run mode.
    init(enabled: Bool = true) {
        if enabled, UpdatePolicy.inAppUpdatesSupported(isAppStoreBuild: Self.isAppStoreBuild) {
            controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        } else {
            controller = nil
        }
        super.init()
    }

    /// Whether in-app updates are offered in this build (false on the Mac App Store).
    var isAvailable: Bool { controller != nil }

    /// Sparkle's background-check preference. Sparkle persists this itself under `SUEnableAutomaticChecks`
    /// in standard UserDefaults — deliberately NOT mirrored into the `bosun.preferences` blob, to avoid a
    /// second source of truth. The Settings ▸ General toggle reads/writes this directly.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Menu action for "Check for Updates…": shows Sparkle's checking / up-to-date / update-available UI.
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// Mirror Sparkle's own menu validation so "Check for Updates…" greys out while a check is mid-flight.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let controller else { return false }
        if item.action == #selector(checkForUpdates(_:)) {
            return controller.updater.canCheckForUpdates
        }
        return true
    }

    /// True when launched from a Mac App Store install — a `_MASReceipt/receipt` sits in the bundle.
    private static var isAppStoreBuild: Bool {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: receipt.path)
    }
}
