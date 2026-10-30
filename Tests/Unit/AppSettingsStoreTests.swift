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
            defaults.set(raw, forKey: "properwm.taskbarHeight")
            let store = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(store.dockPanelHeight, DockPanelHeight(clamping: CGFloat(raw)))
            XCTAssertEqual(defaults.double(forKey: "properwm.taskbarHeight"),
                           Double(store.dockPanelHeight.points))
        }
    }

    func testMalformedHeightFallsBackToDefault() {
        let values: [Any] = ["invalid", true, ["height": 73]]
        for value in values {
            let defaults = makeDefaults()
            defaults.set(value, forKey: "properwm.taskbarHeight")
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

    func testRemovedPreferencesCannotOverrideFixedBehavior() {
        let defaults = makeDefaults()
        defaults.set("followMouse", forKey: "properwm.legacy.taskbarScreen.mode")
        defaults.set("quiet", forKey: "properwm.legacy.hoverStyle")
        defaults.set(false, forKey: "properwm.legacy.windowLiftEnabled")
        defaults.set(false, forKey: "properwm.legacy.fullscreenIntentEnabled")
        defaults.set(2.0, forKey: "properwm.legacy.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.taskbarScreenPlacement, .allScreensPerDisplay)
        XCTAssertEqual(store.hoverStyle, .standard)
        XCTAssertTrue(store.windowLiftEnabled)
        XCTAssertTrue(store.fullscreenIntentEnabled)
        XCTAssertFalse(store.edgeAutoHideEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ProperWM.AppSettingsStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}
