import Application
import Domain
import Foundation

/// UserDefaults adapter for the `PreferencesStore` port: the `Preferences` value encoded as a
/// single JSON blob under one key. Conforms to the same port as any future store, so
/// `CompositionRoot` can swap it without the App layer noticing. An actor gives us free
/// `Sendable` correctness, mirroring `JSONFileConnectionStore`. Both operations are
/// best-effort: `load` falls back to defaults on missing or corrupt data, and `save` silently
/// drops an unencodable value — a UI preference must never crash the app.
public actor UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "bosun.preferences") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return .default }
        return prefs
    }

    public func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
