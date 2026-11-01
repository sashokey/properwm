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

    private func makeDefaults() -> UserDefaults {
        let suite = "ProperWM.AppSettingsStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}
