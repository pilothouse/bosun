import AppKit

/// Shared UI state for the Workbench. Views register an `observe` closure that
/// fires on any data/theme change (used to re-apply content + colors).
final class Store {
    enum Tab { case prs, issues }
    enum GroupBy: String, CaseIterable {
        case none = "Flat list"
        case parent = "By parent"
        case blocked = "By blocked-by"
    }

    var themeKey = "operator" { didSet { if oldValue != themeKey { notify() } } }
    var theme: Theme { Theme.named(themeKey) }

    var railCollapsed = false { didSet { if oldValue != railCollapsed { notify() } } }
    var tab: Tab = .prs { didSet { if oldValue != tab { notify() } } }
    var groupBy: GroupBy = .none { didSet { if oldValue != groupBy { notify() } } }
    var viewMenuOpen = false { didSet { if oldValue != viewMenuOpen { notify() } } }
    var settingsOpen = false { didSet { if oldValue != settingsOpen { notify() } } }

    var selectedConnId = "api-gateway" { didSet { if oldValue != selectedConnId { notify() } } }
    var selectedItemId = "482" { didSet { if oldValue != selectedItemId { notify() } } }
    var expandedOrgs: Set<String> = ["acme-corp"] { didSet { notify() } }

    /// Terminal height drives layout only (no content rebuild), so it is not part of `notify`.
    var terminalHeight: CGFloat = 240

    var selectedConn: Connection {
        Mock.connections.first { $0.id == selectedConnId } ?? Mock.connections[0]
    }
    var selectedItem: Item? { Mock.item(id: selectedItemId) }

    var listItems: [Item] { tab == .prs ? Mock.prs : Mock.issues }

    private var observers: [() -> Void] = []
    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    private func notify() { observers.forEach { $0() } }

    /// Force a content refresh (e.g., after the terminal view is attached).
    func refresh() { notify() }
}
