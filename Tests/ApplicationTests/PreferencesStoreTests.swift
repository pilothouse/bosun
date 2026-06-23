import XCTest
import Domain
@testable import Application

/// Contract tests for the `PreferencesStore` port, driven through a fake. They describe the
/// port's promise — load returns defaults until something is saved, and a save round-trips —
/// not how any concrete adapter stores the bytes.
final class PreferencesStoreTests: XCTestCase {

    private actor FakePreferencesStore: PreferencesStore {
        private var stored: Preferences?
        func load() -> Preferences { stored ?? .default }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    func testLoadReturnsDefaultsBeforeAnythingIsSaved() async {
        let loaded = await FakePreferencesStore().load()

        XCTAssertEqual(loaded, .default)
    }

    func testSaveThenLoadRoundTrips() async {
        let store = FakePreferencesStore()
        let prefs = Preferences(
            themeKey: "nord",
            terminalHeight: 480,
            selectedConnId: "db-primary",
            selectedItemId: "991",
            windowAlpha: 0.8
        )

        await store.save(prefs)
        let loaded = await store.load()

        XCTAssertEqual(loaded, prefs)
    }

    func testLastSaveWins() async {
        let store = FakePreferencesStore()

        await store.save(Preferences(themeKey: "carbon"))
        await store.save(Preferences(themeKey: "light"))
        let loaded = await store.load()

        XCTAssertEqual(loaded.themeKey, "light")
    }
}
