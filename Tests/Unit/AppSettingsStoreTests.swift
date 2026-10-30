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

    func testHeightDefaultsAndPersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.dockPanelHeight, .default)
        let height = DockPanelHeight(clamping: 73)
        store.setDockPanelHeight(height)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight, height)
    }

    func testStoredHeightClampsToSupportedRange() {
        let defaults = makeDefaults()
        for raw in [-1000.0, 1000.0] {
            defaults.set(raw, forKey: "com.tungsten.edge.dockPanelHeight")
            let store = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(store.dockPanelHeight, DockPanelHeight(clamping: CGFloat(raw)))
            XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.dockPanelHeight"),
                           Double(store.dockPanelHeight.points))
        }
    }

    func testMalformedHeightFallsBackToDefault() {
        let values: [Any] = ["invalid", true, ["height": 73]]
        for value in values {
            let defaults = makeDefaults()
            defaults.set(value, forKey: "com.tungsten.edge.dockPanelHeight")
            XCTAssertEqual(AppSettingsStore(defaults: defaults).dockPanelHeight, .default)
        }
    }

    func testUnchangedValuesDoNotPublishAnotherUpdate() {
        let store = AppSettingsStore(defaults: makeDefaults())
        var heights: [DockPanelHeight] = []
        var loginChoices: [Bool] = []
        let heightSubscription = store.$dockPanelHeight.dropFirst().sink { heights.append($0) }
        let loginSubscription = store.$launchAtLogin.dropFirst().sink { loginChoices.append($0) }
        store.setDockPanelHeight(store.dockPanelHeight)
        store.setLaunchAtLogin(store.launchAtLogin)
        XCTAssertTrue(heights.isEmpty)
        XCTAssertTrue(loginChoices.isEmpty)
        withExtendedLifetime((heightSubscription, loginSubscription)) {}
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ProperWM.AppSettingsStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}
