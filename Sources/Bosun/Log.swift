import Foundation
import os

/// Categorized `os.Logger` facade — the single home for the app's diagnostic logging (#59), replacing
/// the scattered `NSLog` calls. Every line lands in the unified log under one subsystem so a user (or a
/// developer chasing a post-release bug) can pull them with Console.app, `log show`, or **Help → Copy
/// Diagnostics**, filtered to a single category.
///
/// Levels follow the os.log convention: `.error` = lost functionality the user cares about; `.notice` =
/// a recovered/cosmetic condition (still persisted to disk); `.debug` = dev-only verbose (not
/// persisted, fine for the env-gated smoke probe). Interpolated *values* at the call sites are marked
/// `privacy: .public` so locally-pulled diagnostics read the real text rather than `<private>` — none
/// of these sites interpolate a secret, and `DiagnosticsReport.redact` is the backstop that strips any
/// token before a report is copied off the machine.
enum Log {
    /// A fixed constant rather than `Bundle.main.bundleIdentifier` alone so the `log show` / Console
    /// predicate is byte-identical in a packaged build and a bare `swift run` dev build (where
    /// `bundleIdentifier` is nil). Matches `BUNDLE_ID` in `scripts/package-app.sh`.
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.jeckerson.bosun"

    /// App lifecycle / resources (dock icon, bundle).
    static let app = Logger(subsystem: subsystem, category: "app")
    /// AppKit view rendering diagnostics (e.g. the PR/issue list reconcile build-vs-reuse counts).
    static let ui = Logger(subsystem: subsystem, category: "ui")
    /// GitHub data fetches and their cache/per-repo fallbacks.
    static let githubData = Logger(subsystem: subsystem, category: "github-data")
    /// libghostty runtime / surface failures.
    static let ghostty = Logger(subsystem: subsystem, category: "ghostty")
    /// Shell integration (zsh shim) failures.
    static let shell = Logger(subsystem: subsystem, category: "shell")
    /// The dev-only `BOSUN_API_SMOKE` probe.
    static let smoke = Logger(subsystem: subsystem, category: "api-smoke")
}
