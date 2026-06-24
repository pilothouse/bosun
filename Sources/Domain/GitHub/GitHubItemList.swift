import Foundation

/// The result of a list fetch: the items, plus whether closed/merged history was bounded. When a
/// broad status selection reaches into very large closed history, the adapter stops at
/// `GitHubItemStates.historyCap`; `reachedHistoryCap` lets the App layer surface that older items
/// weren't loaded rather than silently truncating. The open-only fast path is unbounded, so it
/// always reports `false`.
public struct GitHubItemList: Sendable, Equatable {
    public let items: [GitHubItem]
    public let reachedHistoryCap: Bool

    public init(items: [GitHubItem], reachedHistoryCap: Bool = false) {
        self.items = items
        self.reachedHistoryCap = reachedHistoryCap
    }
}
