import XCTest
@testable import Domain

/// Contract tests for the pure diagnostics-report rule (#59). They describe what `DiagnosticsReport`
/// promises outward — a deterministic plaintext report composed from structured inputs, entries kept
/// in the order given, and any GitHub token / `Bearer` secret redacted before it reaches the report —
/// not how it works inside. The App layer reads the unified log and hands plain values in, so this
/// owns only the formatting + privacy decision and runs from a test with zero setup (like `AppVersion`).
/// Don't edit a contract test to make an implementation pass — if the contract is wrong, flag it.
final class DiagnosticsReportTests: XCTestCase {
    private func entry(_ ts: String, _ category: String, _ level: String, _ message: String) -> DiagnosticLogEntry {
        DiagnosticLogEntry(timestamp: ts, category: category, level: level, message: message)
    }

    func testComposeLayoutIsDeterministic() {
        let report = DiagnosticsReport.compose(
            appName: "Bosun",
            version: AppVersion.info(shortVersion: "0.1.0", build: "45"),
            osVersion: "Version 14.5 (Build 23F79)",
            entries: [
                entry("2026-06-29T10:00:01Z", "ghostty", "error", "ghostty_init failed"),
                entry("2026-06-29T10:00:02Z", "github-data", "notice",
                      "batched org fetch failed; falling back to per-repo"),
            ])

        let expected = """
        Bosun Diagnostics
        App: Bosun 0.1.0 (45)
        macOS: Version 14.5 (Build 23F79)
        Log entries: 2

        2026-06-29T10:00:01Z  [ERROR] ghostty: ghostty_init failed
        2026-06-29T10:00:02Z  [NOTICE] github-data: batched org fetch failed; falling back to per-repo
        """
        XCTAssertEqual(report, expected)
    }

    func testEntriesPreserveInputOrder() {
        // Given newest-first input, the composer must NOT sort — it emits in the order handed in.
        let report = DiagnosticsReport.compose(
            appName: "Bosun",
            version: AppVersion.info(shortVersion: "0.1.0", build: "45"),
            osVersion: "macOS 14",
            entries: [
                entry("2026-06-29T10:00:09Z", "app", "notice", "second-in-time first-in-list"),
                entry("2026-06-29T10:00:01Z", "app", "notice", "first-in-time second-in-list"),
            ])
        guard let firstIdx = report.range(of: "first-in-list")?.lowerBound,
              let secondIdx = report.range(of: "second-in-list")?.lowerBound else {
            return XCTFail("both entries should appear in the report")
        }
        XCTAssertLessThan(firstIdx, secondIdx, "entries must keep input order, not be re-sorted")
    }

    func testEmptyEntriesProducesHeaderOnly() {
        let report = DiagnosticsReport.compose(
            appName: "Bosun",
            version: AppVersion.info(shortVersion: "0.1.0", build: "45"),
            osVersion: "macOS 14",
            entries: [])

        let expected = """
        Bosun Diagnostics
        App: Bosun 0.1.0 (45)
        macOS: macOS 14
        Log entries: 0

        (no log entries)
        """
        XCTAssertEqual(report, expected)
    }

    func testRedactsGitHubTokens() {
        for prefix in ["ghp", "gho", "ghu", "ghs", "ghr"] {
            let token = "\(prefix)_AbCdEf0123456789AbCdEf0123456789abcd"
            let out = DiagnosticsReport.redact("auth failed with \(token) — retrying")
            XCTAssertFalse(out.contains(token), "\(prefix)_ token leaked into the report")
            XCTAssertTrue(out.contains("***REDACTED***"), "\(prefix)_ token not marked redacted")
            XCTAssertTrue(out.contains("\(prefix)_"), "the prefix should survive so the report still notes a token was present")
        }

        let pat = "github_pat_11ABCDEFG0aBcDeFgHiJkL_mNoPqRsTuVwXyZ0123456789AbCdEfGh"
        let out = DiagnosticsReport.redact("token=\(pat) used")
        XCTAssertFalse(out.contains(pat), "fine-grained PAT leaked into the report")
        XCTAssertTrue(out.contains("github_pat_***REDACTED***"))
    }

    func testRedactsBearerTokens() {
        let secret = "eyJhbGci.OiJIUzI1NiJ9-abc_123"
        let out = DiagnosticsReport.redact("Authorization: Bearer \(secret)")
        XCTAssertFalse(out.contains(secret), "bearer token leaked into the report")
        XCTAssertTrue(out.contains("Bearer ***REDACTED***"))
    }

    func testRedactionLeavesOrdinaryTextIntact() {
        // None of these contain a secret. In particular `gho` in "ghostty_init" is NOT followed by
        // `_`, and "github-data" is not "github_pat_", so neither must be touched.
        for message in [
            "org item fetch phalcon/cphalcon failed; using cache",
            "ghostty_init failed",
            "batched org fetch failed (github-data); falling back to per-repo",
        ] {
            XCTAssertEqual(DiagnosticsReport.redact(message), message)
        }
    }

    func testDevVersionRendersDevMarker() {
        let report = DiagnosticsReport.compose(
            appName: "Bosun",
            version: AppVersion.info(shortVersion: nil, build: nil),
            osVersion: "macOS 14",
            entries: [])
        XCTAssertTrue(report.contains("App: Bosun dev"), "an unbundled dev build should read 'Bosun dev'")
    }
}
