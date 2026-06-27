import Foundation

/// The slice of `NSUbiquitousKeyValueStore` the connection-sync decorator needs, behind a protocol so
/// the decorator's merge orchestration is unit-testable against an in-memory fake. This is the single
/// seam where iCloud is touched — `NSUbiquitousKeyValueStore` itself appears only in the real adapter
/// below, never in Domain/Application.
protocol UbiquitousKeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
    /// Register the handler iCloud calls when *another device* writes (the change-externally signal).
    /// Called once, after the decorator is constructed, because the handler captures it.
    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void)
}

/// Real adapter over `NSUbiquitousKeyValueStore.default`. `@unchecked Sendable`: the underlying store
/// is thread-safe for these accessors, and `observe` is wired exactly once at launch, so there's no
/// concurrent mutation to guard. The decorator (an actor) owns all calls into it.
final class ICloudKeyValueStore: UbiquitousKeyValueStore, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) { store.set(data, forKey: key) }
    @discardableResult func synchronize() -> Bool { store.synchronize() }

    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: nil) { _ in handler() }
        // Prime the pump: pull whatever iCloud already holds for this account.
        store.synchronize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
