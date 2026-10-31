import AppKit
import Combine
import XCTest

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testLoginChoiceDefaultsToOffAndPersistsBothValues() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(store.launchAtLogin)
        store.setLaunchAtLogin(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).launchAtLogin)
        store.setLaunchAtLogin(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).launchAtLogin)
    }

    func testUnchangedValuesDoNotPublishAnotherUpdate() {
        let store = AppSettingsStore(defaults: makeDefaults())
        var loginChoices: [Bool] = []
        let loginSubscription = store.$launchAtLogin.dropFirst().sink { loginChoices.append($0) }
        store.setLaunchAtLogin(store.launchAtLogin)
        XCTAssertTrue(loginChoices.isEmpty)
        withExtendedLifetime(loginSubscription) {}
    }

    func testRemovedPreferencesCannotOverrideFixedBehavior() {
        let defaults = makeDefaults()
        defaults.set("followMouse", forKey: "properwm.legacy.taskbarScreen.mode")
        defaults.set("quiet", forKey: "properwm.legacy.hoverStyle")
        defaults.set(false, forKey: "properwm.legacy.windowLiftEnabled")
        defaults.set(false, forKey: "properwm.legacy.fullscreenIntentEnabled")
        defaults.set(2.0, forKey: "properwm.legacy.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(store.windowLiftEnabled)
        XCTAssertTrue(store.fullscreenIntentEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ProperWM.AppSettingsStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}
