import Foundation

/// One unified-log line, flattened to plain strings. The App layer reads `OSLogStore` and pre-formats
/// the timestamp + level (so this rule owns no clock and no `OSLog` types), exactly as `AppVersion`
/// takes raw Info.plist strings rather than reaching for `Bundle`.
public struct DiagnosticLogEntry: Equatable {
    /// Pre-formatted instant (the App layer renders the `Date`, e.g. ISO 8601), so composition is
    /// deterministic and time-source-free.
    public let timestamp: String
    /// The logger category the line came from (`ghostty`, `github-data`, …).
    public let category: String
    /// The severity, lowercased (`error`, `notice`, `info`, `debug`, `fault`).
    public let level: String
    /// The composed log message.
    public let message: String

    public init(timestamp: String, category: String, level: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Pure rule (#59) for turning the app version, OS version, and recent log lines into a single
/// plaintext diagnostics report the user can paste into an issue — and for stripping any secret out
/// of a log message first. No I/O, no clock: it owns only the layout + the redaction decision, so it
/// runs from a unit test with zero setup. Privacy lives here on purpose — the App layer marks log
/// interpolations `.public` so locally-pulled diagnostics are readable, and this is the single seam
/// that guarantees a token can never ride along into a copied report.
public enum DiagnosticsReport {
    /// Marker substituted for any redacted secret.
    public static let redactionMarker = "***REDACTED***"

    /// Compose the report. Entries are emitted in the order given (the caller already ordered them
    /// oldest→newest); this never sorts. Each message is `redact`-ed before it lands in the output.
    public static func compose(appName: String,
                               version: AppVersion.Info,
                               osVersion: String,
                               entries: [DiagnosticLogEntry]) -> String {
        let header = [
            "\(appName) Diagnostics",
            "App: \(appName) \(version.displayString)",
            "macOS: \(osVersion)",
            "Log entries: \(entries.count)",
        ].joined(separator: "\n")

        let body: String
        if entries.isEmpty {
            body = "(no log entries)"
        } else {
            body = entries.map { entry in
                "\(entry.timestamp)  [\(entry.level.uppercased())] \(entry.category): \(redact(entry.message))"
            }.joined(separator: "\n")
        }

        return "\(header)\n\n\(body)"
    }

    /// Replace any GitHub token (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` classic, `github_pat_`
    /// fine-grained) or `Bearer <token>` with `***REDACTED***`, leaving the surrounding text — and the
    /// classic prefix — intact so the report still notes that a token was present. The prefix anchors
    /// avoid false positives: `gho` in "ghostty_init" isn't followed by `_`, and "github-data" isn't
    /// "github_pat_".
    public static func redact(_ message: String) -> String {
        var out = message
        // Fine-grained PAT first (its body contains `_`, so match it before the classic rule).
        out = replace(out, #"github_pat_[A-Za-z0-9_]+"#, with: "github_pat_\(redactionMarker)")
        // Classic tokens: keep the 3-letter prefix, redact the body.
        out = replace(out, #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]+"#, with: "$1_\(redactionMarker)")
        // Authorization bearer tokens (base64url body + `.`/padding), normalized to "Bearer".
        out = replace(out, #"[Bb]earer\s+[\w.\-+/=]+"#, with: "Bearer \(redactionMarker)")
        return out
    }

    /// Best-effort regex replace; on a malformed pattern the input is returned unchanged so redaction
    /// can never throw into the diagnostics path (a failure here must degrade, not crash).
    private static func replace(_ string: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }
}
