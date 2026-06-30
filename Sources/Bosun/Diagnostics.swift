import AppKit
import Domain
import Foundation
import OSLog

/// The Help-menu diagnostics affordances (#59). Kept out of `AppDelegate.swift` so that file stays
/// under the `file_length` warning, and so the `OSLogStore` glue lives next to the `Log` facade it
/// reads back. There is no business rule here — composition + secret redaction is the pure Domain rule
/// `DiagnosticsReport`; this is just the boundary that reads the unified log and writes the clipboard,
/// so per CLAUDE.md's "light path" it needs no Application port (and `OSLogStore` can't be faked anyway).
extension AppDelegate {
    /// The app's version, resolved from the Info.plist (absent in a bare `swift build`, mapped to a
    /// "dev" marker by `AppVersion`). Shared by the About panel and the diagnostics report.
    static func appVersionInfo() -> AppVersion.Info {
        AppVersion.info(
            shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    /// Append a standard macOS **Help** menu (the app otherwise has none) with the diagnostics items.
    /// Same target/action wiring as the rest of `installMenu()`.
    func installHelpMenu(into mainMenu: NSMenu) {
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            helpMenu.addItem(item)
        }
        add("Copy Diagnostics", #selector(copyDiagnostics))
        add("Reveal Crash Reports", #selector(revealCrashReports))
        add("Open Console", #selector(openConsole))
        helpItem.submenu = helpMenu
    }

    /// Gather app + OS version and this run's recent log lines into a redacted plaintext report and put
    /// it on the clipboard, ready to paste into a GitHub issue. Silent, matching the other copy
    /// affordances (`DeviceFlowSheet`, `DetailView`).
    @objc func copyDiagnostics() {
        let report = DiagnosticsReport.compose(
            appName: "Bosun",
            version: Self.appVersionInfo(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            entries: Self.recentLogEntries())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    /// Open `~/Library/Logs/DiagnosticReports`, where macOS writes Bosun's `.ips` crash reports — the
    /// post-crash artifact `OSLogStore` (current-process scope) can't reach.
    @objc func revealCrashReports() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        NSWorkspace.shared.open(dir)
    }

    /// Launch Console.app. Unified logging exposes no URL scheme to pre-filter it to our subsystem, so
    /// the user filters manually (or uses the `log show` predicate documented in the PR).
    @objc func openConsole() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        }
    }

    /// Read this process's own recent unified-log entries for our subsystem (no entitlement needed at
    /// `.currentProcessIdentifier` scope), newest `limit` within the time window, flattened to the pure
    /// `DiagnosticLogEntry` value the Domain composer takes. `.debug`/`.info` lines aren't persisted to
    /// the store, so this surfaces the `.notice`/`.error`/`.fault` lines that actually matter for a bug
    /// report. A read failure degrades to an empty list (the report header is still useful).
    static func recentLogEntries(within seconds: TimeInterval = 15 * 60, limit: Int = 500) -> [DiagnosticLogEntry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-seconds))
            let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let formatter = ISO8601DateFormatter()
            return try store.getEntries(at: since, matching: predicate)
                .compactMap { $0 as? OSLogEntryLog }
                .suffix(limit)
                .map { entry in
                    DiagnosticLogEntry(
                        timestamp: formatter.string(from: entry.date),
                        category: entry.category,
                        level: levelName(entry.level),
                        message: entry.composedMessage)
                }
        } catch {
            Log.app.error("diagnostics: failed to read log store: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Lowercase name for an `OSLogEntryLog.Level`, matching the `Log` facade's level vocabulary.
    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "default"
        @unknown default: return "default"
        }
    }
}
