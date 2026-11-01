import AppKit
import Combine
import XCTest

@MainActor
final class SettingsCoordinatorTests: XCTestCase {
    func testLaunchStateStartsFromCacheThenRefreshesFromService() async {
        let store = makeStore(launchAtLogin: true)
        let launch = LaunchServiceStub(state: .off)
        let coordinator = makeCoordinator(store: store, launch: launch)

        XCTAssertEqual(coordinator.launchAtLoginState, .on)
        let firstRefreshAccepted = await coordinator.refreshLaunchAtLoginState()
        XCTAssertTrue(firstRefreshAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .off)

        launch.state = .requiresApproval
        let secondRefreshAccepted = await coordinator.refreshLaunchAtLoginState()
        XCTAssertTrue(secondRefreshAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .requiresApproval)
    }

    func testLaunchFailureDoesNotChangeStoredMirror() {
        let store = makeStore(launchAtLogin: false)
        let launch = LaunchServiceStub(state: .off)
        launch.setError = TestError.failed
        let coordinator = makeCoordinator(store: store, launch: launch)

        guard case .failure = coordinator.setLaunchAtLogin(true) else {
            return XCTFail("expected failure")
        }
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(coordinator.launchAtLoginState, .off)
    }

    func testLaunchSuccessUpdatesMirrorAndPublishedState() {
        let store = makeStore(launchAtLogin: false)
        let launch = LaunchServiceStub(state: .off)
        launch.stateAfterSet = .on
        let coordinator = makeCoordinator(store: store, launch: launch)

        guard case .success = coordinator.setLaunchAtLogin(true) else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(coordinator.launchAtLoginState, .on)
    }

    func testOlderLaunchRefreshCannotOverwriteNewerResult() async {
        let reader = ControlledLaunchStateReader()
        let launch = ControlledLaunchService(reader: reader)
        let coordinator = SettingsCoordinator(
            store: makeStore(),
            launchAtLoginService: launch
        )

        let older = Task { await coordinator.refreshLaunchAtLoginState() }
        await reader.waitForReadCount(1)
        let newer = Task { await coordinator.refreshLaunchAtLoginState() }
        await reader.waitForReadCount(2)

        await reader.resume(id: 1, state: .on)
        let newerAccepted = await newer.value
        XCTAssertTrue(newerAccepted)
        await reader.resume(id: 0, state: .off)
        let olderAccepted = await older.value
        XCTAssertFalse(olderAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .on)
    }

    func testCancelledRefreshDoesNotPublishAResult() async {
        let reader = ControlledLaunchStateReader()
        let launch = ControlledLaunchService(reader: reader)
        let coordinator = makeCoordinator(launch: launch)
        let refresh = Task { await coordinator.refreshLaunchAtLoginState() }
        await reader.waitForReadCount(1)
        refresh.cancel()
        await reader.resume(id: 0, state: .on)
        let accepted = await refresh.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .off)
    }

    func testLaunchApprovalCanOpenSystemSettings() {
        let launch = LaunchServiceStub(state: .requiresApproval)
        let coordinator = makeCoordinator(launch: launch)
        coordinator.openLoginItemsSettings()
        XCTAssertEqual(launch.settingsOpenCount, 1)
    }

    func testDisablingLoginUpdatesTheStoredChoice() {
        let store = makeStore(launchAtLogin: true)
        let launch = LaunchServiceStub(state: .on)
        let coordinator = makeCoordinator(store: store, launch: launch)
        guard case .success = coordinator.setLaunchAtLogin(false) else {
            return XCTFail("Expected successful disable")
        }
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(coordinator.launchAtLoginState, .off)
        XCTAssertEqual(launch.requests, [false])
    }

    private func makeCoordinator(
        store: AppSettingsStore? = nil,
        launch: LaunchAtLoginServicing? = nil
    ) -> SettingsCoordinator {
        SettingsCoordinator(
            store: store ?? makeStore(),
            launchAtLoginService: launch ?? LaunchServiceStub(state: .off)
        )
    }

    private func makeStore(launchAtLogin: Bool = false) -> AppSettingsStore {
        let suite = "ProperWM.SettingsCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(launchAtLogin, forKey: "properwm.launchAtLogin")
        return AppSettingsStore(defaults: defaults)
    }
}

@MainActor
private final class LaunchServiceStub: LaunchAtLoginServicing {
    var state: LaunchAtLoginState
    var stateAfterSet: LaunchAtLoginState?
    var setError: Error?
    private(set) var settingsOpenCount = 0
    private(set) var requests: [Bool] = []

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func currentState() async -> LaunchAtLoginState { state }

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if let setError { throw setError }
        state = stateAfterSet ?? (enabled ? .on : .off)
    }

    func openSystemSettings() {
        settingsOpenCount += 1
    }
}

private actor ControlledLaunchStateReader {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<LaunchAtLoginState, Never>] = [:]

    func read() async -> LaunchAtLoginState {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }

    func waitForReadCount(_ count: Int) async {
        while nextID < count { await Task.yield() }
    }

    func resume(id: Int, state: LaunchAtLoginState) {
        continuations.removeValue(forKey: id)?.resume(returning: state)
    }
}

@MainActor
private final class ControlledLaunchService: LaunchAtLoginServicing {
    private let reader: ControlledLaunchStateReader

    init(reader: ControlledLaunchStateReader) {
        self.reader = reader
    }

    func currentState() async -> LaunchAtLoginState { await reader.read() }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}

private enum TestError: Error {
    case failed
}

@MainActor
final class StatusMenuControllerTests: XCTestCase {
    private final class StatusItem: StatusItemPresenting {
        var autosaveName: NSStatusItem.AutosaveName?
        var menu: NSMenu?
        var image: NSImage?
        private var visible: Bool
        private(set) var visibilityWrites: [Bool] = []
        private(set) var imageConfigurations = 0

        var isVisible: Bool {
            get { visible }
            set { visible = newValue; visibilityWrites.append(newValue) }
        }

        init(visible: Bool = true) { self.visible = visible }

        func configureAutosaveName(_ name: NSStatusItem.AutosaveName) { autosaveName = name }

        func configureButtonImage(_ image: NSImage?) {
            self.image = image
            imageConfigurations += 1
        }
    }

    private func makeController(item: StatusItem, launch: LaunchServiceStub,
                                menuVisibility: @escaping (Bool) -> Void = { _ in },
                                quit: @escaping @MainActor () -> Void = {}) -> StatusMenuController {
        let suite = "ProperWM.StatusMenuControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let coordinator = SettingsCoordinator(store: AppSettingsStore(defaults: defaults), launchAtLoginService: launch)
        return StatusMenuController(settingsCoordinator: coordinator, onMenuVisibilityChanged: menuVisibility,
                                    statusItem: item, quit: quit)
    }

    func testHideActionChangesOnlyStatusItemVisibilityAndMenuRefreshDoesNotRestoreIt() throws {
        let item = StatusItem()
        let launch = LaunchServiceStub(state: .off)
        var quits = 0
        var menuVisibility: [Bool] = []
        let controller = makeController(item: item, launch: launch,
                                        menuVisibility: { menuVisibility.append($0) }, quit: { quits += 1 })
        let menu = try XCTUnwrap(item.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Open at Login", "Hide Status Bar Icon", "", "Quit"])
        XCTAssertEqual(menu.items[1].state, .off)
        menu.performActionForItem(at: 1)
        XCTAssertFalse(item.isVisible)
        XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[1].state, .on)
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)
        XCTAssertFalse(item.isVisible)
        XCTAssertEqual(menuVisibility, [true, false])
        XCTAssertEqual(quits, 0)
        XCTAssertTrue(launch.requests.isEmpty)
    }

    func testNativeRestoredVisibilityIsNotOverriddenAtStartup() throws {
        let item = StatusItem(visible: false)
        let controller = makeController(item: item, launch: LaunchServiceStub(state: .off))
        withExtendedLifetime(controller) {
            XCTAssertEqual(item.autosaveName, "ProperWM.StatusBarIcon")
            XCTAssertFalse(item.isVisible)
            XCTAssertTrue(item.visibilityWrites.isEmpty)
            XCTAssertEqual(item.menu?.items[1].isEnabled, true)
            XCTAssertEqual(item.menu?.items[1].state, .on)
            XCTAssertEqual(item.image?.isTemplate, true)
        }
    }

    func testRestoringTheIconReusesItsMenuAndStablePersistenceIdentity() throws {
        let item = StatusItem(visible: false)
        let controller = makeController(item: item, launch: LaunchServiceStub(state: .off))
        let menu = try XCTUnwrap(item.menu)
        controller.showStatusBarIcon()
        controller.showStatusBarIcon()
        XCTAssertTrue(item.isVisible)
        XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[1].state, .off)
        XCTAssertTrue(item.menu === menu)
        XCTAssertEqual(item.imageConfigurations, 1)
        XCTAssertEqual(item.autosaveName, "ProperWM.StatusBarIcon")
        let restoredItem = StatusItem(visible: false)
        let restoredController = makeController(item: restoredItem, launch: LaunchServiceStub(state: .off))
        withExtendedLifetime(restoredController) {
            XCTAssertEqual(restoredItem.autosaveName, item.autosaveName)
            XCTAssertFalse(restoredItem.isVisible)
        }
    }

    func testHideMenuItemTogglesBothWaysFromEitherRestoredState() throws {
        for initiallyVisible in [false, true] {
            let item = StatusItem(visible: initiallyVisible)
            let launch = LaunchServiceStub(state: .off)
            let controller = makeController(item: item, launch: launch)
            let menu = try XCTUnwrap(item.menu)
            XCTAssertTrue(item.visibilityWrites.isEmpty)
            for expectedVisibility in [!initiallyVisible, initiallyVisible, !initiallyVisible] {
                controller.menuWillOpen(menu)
                XCTAssertTrue(menu.items[1].isEnabled)
                XCTAssertEqual(menu.items[1].state, item.isVisible ? .off : .on)
                menu.performActionForItem(at: 1)
                controller.menuDidClose(menu)
                XCTAssertEqual(item.isVisible, expectedVisibility)
                XCTAssertEqual(menu.items[1].state, expectedVisibility ? .off : .on)
                XCTAssertTrue(menu.items[1].isEnabled)
            }
            XCTAssertEqual(item.visibilityWrites, [!initiallyVisible, initiallyVisible, !initiallyVisible])
            XCTAssertTrue(launch.requests.isEmpty)
            XCTAssertTrue(item.menu === menu)
        }
    }

    func testOpeningTheSharedMenuReflectsExternalVisibilityChangesWithoutWritingThem() throws {
        let item = StatusItem()
        let controller = makeController(item: item, launch: LaunchServiceStub(state: .off))
        let menu = try XCTUnwrap(item.menu)
        for visible in [false, true] {
            item.isVisible = visible
            let writes = item.visibilityWrites
            controller.menuWillOpen(menu)
            XCTAssertEqual(menu.items[1].state, visible ? .off : .on)
            XCTAssertTrue(menu.items[1].isEnabled)
            controller.menuDidClose(menu)
            XCTAssertEqual(item.visibilityWrites, writes)
        }
    }

    func testQuitRemainsSeparateFromHidingTheIcon() throws {
        let item = StatusItem()
        var quits = 0
        let controller = makeController(item: item, launch: LaunchServiceStub(state: .off), quit: { quits += 1 })
        let menu = try XCTUnwrap(item.menu)
        withExtendedLifetime(controller) {
            menu.performActionForItem(at: 3)
            XCTAssertEqual(quits, 1)
            XCTAssertTrue(item.isVisible)
            XCTAssertTrue(item.visibilityWrites.isEmpty)
        }
    }

    func testLaunchAtLoginRemainsIndependentOfIconVisibility() throws {
        let item = StatusItem()
        let launch = LaunchServiceStub(state: .off)
        let controller = makeController(item: item, launch: launch)
        let menu = try XCTUnwrap(item.menu)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(launch.requests, [true])
        menu.performActionForItem(at: 1)
        controller.showStatusBarIcon()
        menu.performActionForItem(at: 0)
        XCTAssertEqual(launch.requests, [true, false])
        XCTAssertTrue(item.isVisible)
    }
}
