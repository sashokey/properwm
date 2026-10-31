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
