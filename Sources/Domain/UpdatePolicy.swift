/// Pure rule for whether the app should offer in-app (Sparkle) updates, independent of how the build
/// was distributed. A normally-distributed build (Homebrew Cask / a GitHub-Release DMG) self-updates
/// via a signed appcast; a Mac App Store build must NOT — self-updating code violates App Store rules,
/// and the Store has its own update path. The same answer gates the "Check for Updates…" menu item,
/// whether the updater starts at launch, and the Settings toggle, so the rule lives here once.
///
/// No `Bundle`, no I/O: the app layer detects an App Store build (a `_MASReceipt` in the bundle) and
/// hands the boolean in, so this owns only the decision and runs from a unit test with zero setup
/// (like `AppVersion` / `SessionExpiryPolicy`).
public enum UpdatePolicy {
    /// `true` when the app may present Sparkle updates — every build except a Mac App Store one.
    public static func inAppUpdatesSupported(isAppStoreBuild: Bool) -> Bool {
        !isAppStoreBuild
    }
}
