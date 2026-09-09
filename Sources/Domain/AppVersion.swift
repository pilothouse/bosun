import Foundation

/// Pure rule for presenting the app's version, independent of where the numbers come from. A packaged
/// build carries `CFBundleShortVersionString`/`CFBundleVersion` in its Info.plist; a bare `swift build`
/// executable has no Info.plist, so the raw values arrive `nil` — this maps that case to an explicit
/// "dev" marker rather than a blank or a misleading "0.0.0 (0)". It also drops a build that carries no
/// information: the placeholder (`package-app.sh` defaults `CFBundleVersion` to "0"), or one identical
/// to the short version — release.yml stamps both keys from the release tag, because Sparkle compares
/// `CFBundleVersion` against the feed — so the display reads "0.1.0", never "0.1.0 (0)" or "0.1.0 (0.1.0)".
///
/// No `Bundle`, no I/O: the app layer reads `Bundle.main` and hands the raw strings in, so this owns
/// only the decision and runs from a unit test with zero setup (like `SessionExpiryPolicy`).
public enum AppVersion {
    /// What an unbundled dev build reports when no Info.plist version is present.
    public static let devMarker = "dev"

    public struct Info: Equatable {
        /// Marketing version for the "Version …" line (e.g. "0.1.0", or "dev" when unbundled).
        public let shortVersion: String
        /// Build number shown in parentheses, or `nil` to omit it (missing, blank, the "0" placeholder,
        /// or a plain repeat of `shortVersion`).
        public let build: String?
        /// `true` when no real Info.plist version was found — a local `swift build`.
        public let isDev: Bool

        /// Combined string for an about panel's version line: "0.1.0 (45)", "0.1.0", or "dev".
        public var displayString: String {
            build.map { "\(shortVersion) (\($0))" } ?? shortVersion
        }
    }

    /// Resolve the display values from raw Info.plist strings, treating `nil`/blank as absent.
    public static func info(shortVersion: String?, build: String?) -> Info {
        guard let version = nonBlank(shortVersion) else {
            return Info(shortVersion: devMarker, build: nil, isDev: true)
        }
        let resolvedBuild = nonBlank(build).flatMap { $0 == "0" || $0 == version ? nil : $0 }
        return Info(shortVersion: version, build: resolvedBuild, isDev: false)
    }

    /// The trimmed string, or `nil` if it's missing, empty, or whitespace-only.
    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
