import Foundation
import ServiceManagement
import Synchronization
import XCTest
@testable import ProperWM

final class LaunchAtLoginServiceTests: XCTestCase {
    func testModernStatusMappingPreservesApprovalRequirement() {
        XCTAssertEqual(ModernLoginItemBackend.mapStatus(.enabled), .on)
        XCTAssertEqual(ModernLoginItemBackend.mapStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(ModernLoginItemBackend.mapStatus(.notRegistered), .off)
        XCTAssertEqual(ModernLoginItemBackend.mapStatus(.notFound), .off)
    }

    func testMenuReflectsEnabledAndPendingRegistration() {
        let off = LaunchAtLoginMenuPresentation(state: .off)
        XCTAssertTrue(off.isEnabled)
        XCTAssertFalse(off.isChecked)
        XCTAssertFalse(off.showsSettingsItem)
        XCTAssertTrue(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .off))

        let on = LaunchAtLoginMenuPresentation(state: .on)
        XCTAssertTrue(on.isEnabled)
        XCTAssertTrue(on.isChecked)
        XCTAssertFalse(on.showsSettingsItem)
        XCTAssertFalse(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .on))

        let pending = LaunchAtLoginMenuPresentation(state: .requiresApproval)
        XCTAssertTrue(pending.isEnabled)
        XCTAssertFalse(pending.isChecked)
        XCTAssertTrue(pending.showsSettingsItem)
        XCTAssertTrue(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .requiresApproval))
    }

    @MainActor
    func testServiceReadsOffTheMainThreadAndForwardsRegistrationChanges() async throws {
        let backend = LoginBackendStub(state: .on)
        let service = LaunchAtLoginService(backend: backend)

        let before = await service.currentState()
        XCTAssertEqual(before, .on)
        XCTAssertEqual(backend.snapshot.lastReadWasMainThread, false)

        try service.setEnabled(false)
        let disabled = await service.currentState()
        XCTAssertEqual(disabled, .off)

        try service.setEnabled(true)
        let enabled = await service.currentState()
        XCTAssertEqual(enabled, .on)
        XCTAssertEqual(backend.snapshot.requests, [false, true])
    }

    @MainActor
    func testServiceReturnsPendingApprovalWithoutTreatingItAsEnabled() async {
        let service = LaunchAtLoginService(backend: LoginBackendStub(state: .requiresApproval))
        let state = await service.currentState()
        XCTAssertEqual(state, .requiresApproval)
    }

    @MainActor
    func testRegistrationErrorsPropagateWithoutChangingState() async {
        let backend = LoginBackendStub(state: .off, failsWrites: true)
        let service = LaunchAtLoginService(backend: backend)

        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginBackendStub.Failure, .registration)
        }
        let state = await service.currentState()
        XCTAssertEqual(state, .off)
    }

    @MainActor
    func testOpeningSystemSettingsIsForwardedToTheBackend() {
        let backend = LoginBackendStub(state: .requiresApproval)
        LaunchAtLoginService(backend: backend).openSystemSettings()
        XCTAssertEqual(backend.snapshot.settingsOpenCount, 1)
    }
}

private final class LoginBackendStub: LaunchAtLoginBackend {
    enum Failure: Error { case registration }

    struct State: Sendable {
        var registration: LaunchAtLoginState
        var requests: [Bool] = []
        var settingsOpenCount = 0
        var lastReadWasMainThread: Bool?
    }

    private let storage: Mutex<State>
    private let failsWrites: Bool

    init(state: LaunchAtLoginState, failsWrites: Bool = false) {
        storage = Mutex(State(registration: state))
        self.failsWrites = failsWrites
    }

    var snapshot: State { storage.withLock { $0 } }

    func readState() -> LaunchAtLoginState {
        storage.withLock {
            $0.lastReadWasMainThread = Thread.isMainThread
            return $0.registration
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try storage.withLock {
            if failsWrites { throw Failure.registration }
            $0.requests.append(enabled)
            $0.registration = enabled ? .on : .off
        }
    }

    func openSettings() {
        storage.withLock { $0.settingsOpenCount += 1 }
    }
}
