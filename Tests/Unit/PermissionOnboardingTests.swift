import XCTest

@MainActor
final class PermissionOnboardingTests: XCTestCase {
    func testPermissionWatchdogGateRejectsOverlapAndStoppedGeneration() {
        var gate = PermissionWatchdogGate()
        gate.start()
        guard let oldGeneration = gate.beginProbe() else {
            return XCTFail("first probe should start")
        }
        XCTAssertNil(gate.beginProbe())

        gate.stop()
        gate.start()
        guard let currentGeneration = gate.beginProbe() else {
            return XCTFail("new generation probe should start")
        }
        XCTAssertFalse(gate.completeProbe(generation: oldGeneration))
        XCTAssertTrue(gate.completeProbe(generation: currentGeneration))
    }

    func testClassifiesStableLocations() {
        XCTAssertEqual(location("/Applications/Tungsten Edge.app"), .applications)
        XCTAssertEqual(
            location(NSHomeDirectory() + "/Applications/Tungsten Edge.app"),
            .applications
        )
        XCTAssertEqual(location("/Volumes/Samsung T7/Tungsten Edge.app", readOnly: false), .other)
        XCTAssertEqual(location("/Users/someone/Downloads/Tungsten Edge.app"), .other)
    }

    func testClassifiesTransientLocations() {
        XCTAssertEqual(location("/Volumes/Tungsten Edge 0.7.0/Tungsten Edge.app", readOnly: true), .readOnlyVolume)
        XCTAssertEqual(
            location("/private/var/folders/ab/AppTranslocation/XYZ/d/Tungsten Edge.app"),
            .appTranslocation
        )
    }

    func testTranslocationWinsOverVolumeReadability() {
        XCTAssertEqual(
            location("/Volumes/Foo/AppTranslocation/XYZ/d/Tungsten Edge.app", readOnly: false),
            .appTranslocation
        )
    }

    func testUnknownVolumeReadabilityIsTreatedAsWritable() {
        XCTAssertEqual(location("/Volumes/Whatever/Tungsten Edge.app", readOnly: nil), .other)
    }

    func testTransientLocationsRejectAccessibilityPrompt() {
        XCTAssertFalse(AppInstallLocation.readOnlyVolume.allowsAccessibilityPrompt)
        XCTAssertFalse(AppInstallLocation.appTranslocation.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.applications.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.other.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.readOnlyVolume.isTransient)
        XCTAssertTrue(AppInstallLocation.appTranslocation.isTransient)
        XCTAssertFalse(AppInstallLocation.applications.isTransient)
    }

    func testRelocationWinsEvenWhenTransientCopyIsAlreadyTrusted() {
        let state = PermissionOnboardingState.initial(installLocation: .readOnlyVolume, isTrusted: true)
        XCTAssertEqual(state, .moveToApplications(.readOnlyVolume))
    }

    func testWaitingBecomesStalledAtEightSecondsAndGrantedWhenTrusted() {
        let waiting = PermissionOnboardingState.waiting
        XCTAssertEqual(waiting.updated(isTrusted: false, elapsed: 7.999, stallAfter: 8), .waiting)
        XCTAssertEqual(waiting.updated(isTrusted: false, elapsed: 8, stallAfter: 8), .stalled)
        XCTAssertEqual(waiting.updated(isTrusted: true, elapsed: 99, stallAfter: 8), .granted)
    }

    func testMoveToApplicationsNeverLeavesItsBranch() {
        let state = PermissionOnboardingState.moveToApplications(.appTranslocation)
        XCTAssertEqual(state.updated(isTrusted: true, elapsed: 99, stallAfter: 8), state)
    }

    func testTransientCopyNeverChecksOrRequestsPermission() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .readOnlyVolume,
            initialTrusted: false,
            now: { 0 }
        )
        model.startPolling()
        model.requestSystemPromptIfNeeded()
        model.checkNow()

        XCTAssertEqual(spy.promptCount, 0)
        XCTAssertEqual(model.state, .moveToApplications(.readOnlyVolume))
    }

    func testStableCopyRequestsNativePromptAtMostOnce() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { 0 }
        )
        model.requestSystemPromptIfNeeded()
        model.requestSystemPromptIfNeeded()

        XCTAssertEqual(spy.promptCount, 1)
    }

    func testPollingTransitionsToStalledAfterEightSeconds() {
        let spy = PermissionSpy(trusted: false)
        var clock: TimeInterval = 0
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { clock },
            stallAfter: 8
        )
        model.startPolling()
        XCTAssertEqual(model.state, .waiting)

        clock = 7.999
        model.checkNow()
        XCTAssertEqual(model.state, .waiting)

        clock = 8
        model.checkNow()
        XCTAssertEqual(model.state, .stalled)
        model.stop()
    }

    func testActivationRechecksAndGrantCallbackIsOneShot() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { 0 }
        )
        var grants = 0
        model.onGranted = { grants += 1 }
        model.startPolling()
        XCTAssertEqual(grants, 0)

        spy.trusted = true
        model.applicationDidBecomeActive()
        model.applicationDidBecomeActive()
        model.checkNow()

        XCTAssertEqual(grants, 1)
        XCTAssertEqual(model.state, .granted)
    }

    func testFirstFalseIsUncertainAndTwoSustainedFalsesAreLost() {
        var detector = PermissionLossDetector()
        XCTAssertEqual(detector.record(trusted: true, at: 0), .stable)
        XCTAssertEqual(detector.record(trusted: false, at: 10), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 14.999), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 15), .lost)
    }

    func testSingleFalseNeverBecomesLostNoMatterHowLate() {
        var detector = PermissionLossDetector()
        XCTAssertEqual(detector.record(trusted: false, at: 0), .uncertain)
        XCTAssertEqual(detector.record(trusted: true, at: 100), .stable)
        XCTAssertEqual(detector.record(trusted: false, at: 200), .uncertain)
    }

    func testTrueResetsTheAnchor() {
        var detector = PermissionLossDetector()
        _ = detector.record(trusted: false, at: 0)
        _ = detector.record(trusted: true, at: 1)
        XCTAssertEqual(detector.record(trusted: false, at: 2), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 6.999), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 7), .lost)
    }

    func testEarlyArrivingFalseDoesNotResetTheAnchor() {
        var detector = PermissionLossDetector()
        XCTAssertEqual(detector.record(trusted: false, at: 10), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 5), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 15), .lost)
    }

    func testTransientLaunchNeverPromptsOrStartsApp() {
        var machine = PermissionRecoveryMachine()
        let effects = machine.handle(.launched(location: .readOnlyVolume, trusted: false))

        XCTAssertEqual(machine.phase, .transientShell(.readOnlyVolume))
        XCTAssertEqual(effects, [.setActivationPolicy(.regular), .showGuide])
        XCTAssertFalse(effects.contains(.requestSystemPrompt))
        XCTAssertFalse(effects.contains(.startApp))
    }

    func testTrustedLaunchStartsAppAndWatchdog() {
        var machine = PermissionRecoveryMachine()
        let effects = machine.handle(.launched(location: .applications, trusted: true))

        XCTAssertEqual(machine.phase, .running)
        XCTAssertEqual(effects, [.setActivationPolicy(.accessory), .startApp, .startWatchdog])
    }

    func testInitialGrantContinuesInProcessWithoutRelaunch() {
        var machine = PermissionRecoveryMachine()
        _ = machine.handle(.launched(location: .applications, trusted: false))
        guard case let .onboarding(episode) = machine.phase else { return XCTFail("expected onboarding") }

        let effects = machine.handle(.grantObserved(episode: episode))
        XCTAssertEqual(machine.phase, .running)
        XCTAssertTrue(effects.contains(.startApp))
        XCTAssertFalse(effects.contains(.launchNewInstance(episode: episode)))
        XCTAssertFalse(effects.contains(.restoreLiftedWindows(episode: episode)))
    }

    func testFirstFalseFreezesLiftAndRecoveredTrustUnfreezes() {
        var machine = runningMachine()
        XCTAssertEqual(machine.handle(.trustVerdict(.uncertain)), [.freezeLift])
        XCTAssertEqual(machine.phase, .uncertain)
        XCTAssertEqual(machine.handle(.trustVerdict(.stable)), [.unfreezeLift])
        XCTAssertEqual(machine.phase, .running)
    }

    func testLostTrustSuspendsAndReRegistersWithTheSystem() {
        var machine = runningMachine()
        _ = machine.handle(.trustVerdict(.uncertain))
        let effects = machine.handle(.trustVerdict(.lost))

        guard case let .suspended(episode) = machine.phase else { return XCTFail("expected suspended") }
        XCTAssertEqual(effects, [
            .stopWatchdog,
            .freezeLift,
            .suspendPanelsAndStores,
            .setActivationPolicy(.regular),
            .showGuide,
            .startPermissionEpisode(purpose: .runtimeRecovery, episode: episode),
            .requestSystemPrompt,
        ])
    }

    func testRecoveryRestoresWindowsBeforeReleasingHotKeyAndRelaunching() {
        var machine = suspendedMachine()
        guard case let .suspended(episode) = machine.phase else { return XCTFail("expected suspended") }

        let granted = machine.handle(.grantObserved(episode: episode))
        XCTAssertEqual(machine.phase, .restoringWindows(episode: episode))
        XCTAssertTrue(granted.contains(.restoreLiftedWindows(episode: episode)))

        let restored = machine.handle(.windowsRestored(episode: episode))
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
        XCTAssertEqual(restored, [.updateGuide, .launchNewInstance(episode: episode)])

        XCTAssertEqual(machine.handle(.relaunchSucceeded(episode: episode)), [.terminateSelf])
    }

    func testRepeatedEventsDuringRelaunchDoNotStartASecondRelaunch() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        XCTAssertEqual(machine.handle(.grantObserved(episode: episode)), [])
        XCTAssertEqual(machine.handle(.windowsRestored(episode: episode)), [])
        XCTAssertEqual(machine.handle(.trustVerdict(.lost)), [])
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
    }

    func testStaleEpisodeCompletionsAreDropped() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        XCTAssertEqual(machine.handle(.relaunchSucceeded(episode: episode &- 1)), [])
        XCTAssertEqual(machine.handle(.relaunchFailed(episode: episode &+ 1, message: "x")), [])
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
    }

    func testRelaunchFailureKeepsOldInstanceAliveAndGivesTheHotKeyBack() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        let effects = machine.handle(.relaunchFailed(episode: episode, message: "找不到应用"))
        XCTAssertEqual(machine.phase, .relaunchFailed(episode: episode, message: "找不到应用"))
        XCTAssertEqual(effects, [.updateGuide])
        XCTAssertFalse(effects.contains(.terminateSelf))
    }

    func testRetryStartsAnotherRelaunch() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }
        _ = machine.handle(.relaunchFailed(episode: episode, message: "找不到应用"))

        let effects = machine.handle(.retryRequested)
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
        XCTAssertEqual(effects, [.updateGuide, .launchNewInstance(episode: episode)])
    }

    func testTerminationPreemptsEverythingAndSwallowsLateEvents() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        let effects = machine.handle(.terminationRequested)
        XCTAssertEqual(machine.phase, .terminating)
        XCTAssertEqual(effects, [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode])

        XCTAssertEqual(machine.handle(.windowsRestored(episode: episode)), [])
        XCTAssertEqual(machine.handle(.relaunchSucceeded(episode: episode)), [])
        XCTAssertEqual(machine.handle(.retryRequested), [])
    }

    func testStalledAndRecoveryStalledArePresentedSeparately() {
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .onboarding(episode: 1), onboarding: .stalled),
            .stalled
        )
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .suspended(episode: 2), onboarding: .stalled),
            .recoveryStalled
        )
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .onboarding(episode: 1), onboarding: .waiting),
            .waiting
        )
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .suspended(episode: 2), onboarding: .waiting),
            .recoveryWaiting
        )
    }

    func testNoGuideWhileRunning() {
        XCTAssertNil(PermissionRecoveryMachine.presentation(phase: .running, onboarding: .waiting))
        XCTAssertNil(PermissionRecoveryMachine.presentation(phase: .uncertain, onboarding: .waiting))
        XCTAssertNil(PermissionRecoveryMachine.presentation(phase: .terminating, onboarding: .stalled))
    }

    func testRecoveryEpisodeUsesAFreshModelSoTheSystemPromptCanFireAgain() {
        var clock: TimeInterval = 0
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        var made: [AccessibilityPermissionModel] = []

        let coordinator = PermissionRecoveryCoordinator(
            handler: handler,
            permissionService: spy.service,
            installLocation: .applications,
            now: { clock },
            makeModel: { _, _ in
                let model = AccessibilityPermissionModel(
                    permissionService: spy.service,
                    installLocation: .applications,
                    now: { clock }
                )
                made.append(model)
                return model
            }
        )

        coordinator.launched(trusted: false)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(spy.promptCount, 1)
        XCTAssertEqual(coordinator.presentation, .waiting)

        spy.trusted = true
        made[0].checkNow()
        XCTAssertTrue(handler.calls.contains("startApp"))
        XCTAssertFalse(handler.calls.contains("launchNewInstance"))
        XCTAssertNil(coordinator.presentation)

        spy.trusted = false
        clock = 10
        coordinator.sampleTrust(false)
        XCTAssertEqual(handler.calls.last, "freezeLift")
        XCTAssertNil(coordinator.presentation)

        clock = 20
        coordinator.sampleTrust(false)

        XCTAssertEqual(made.count, 2)
        XCTAssertFalse(made[0] === made[1])
        XCTAssertEqual(spy.promptCount, 2)
        XCTAssertEqual(coordinator.presentation, .recoveryWaiting)
        XCTAssertTrue(handler.calls.contains("suspendPanelsAndStores"))
        XCTAssertTrue(handler.calls.contains("stopWatchdog"))

        coordinator.quit()
    }

    func testTransientCopyCoordinatorNeitherTerminatesNorPrompts() {
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        let coordinator = PermissionRecoveryCoordinator(
            handler: handler,
            permissionService: spy.service,
            installLocation: .appTranslocation
        )

        coordinator.launched(trusted: false)

        XCTAssertEqual(coordinator.presentation, .moveToApplications(.appTranslocation))
        XCTAssertEqual(spy.promptCount, 0)
        XCTAssertFalse(handler.calls.contains("startApp"))
        XCTAssertFalse(handler.calls.contains("startWatchdog"))
    }

    private func location(_ path: String, readOnly: Bool? = false) -> AppInstallLocation {
        AppInstallLocation(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            isReadOnlyVolume: { _ in readOnly }
        )
    }

    private func runningMachine() -> PermissionRecoveryMachine {
        var machine = PermissionRecoveryMachine()
        _ = machine.handle(.launched(location: .applications, trusted: true))
        return machine
    }

    private func suspendedMachine() -> PermissionRecoveryMachine {
        var machine = runningMachine()
        _ = machine.handle(.trustVerdict(.uncertain))
        _ = machine.handle(.trustVerdict(.lost))
        return machine
    }

    private func relaunchingMachine() -> PermissionRecoveryMachine {
        var machine = suspendedMachine()
        guard case let .suspended(episode) = machine.phase else { return machine }
        _ = machine.handle(.grantObserved(episode: episode))
        _ = machine.handle(.windowsRestored(episode: episode))
        return machine
    }
}

@MainActor
private final class EffectSpy: PermissionEffectHandler {
    var calls: [String] = []
    var launchResult: Result<Void, Error> = .success(())

    func startApp() { calls.append("startApp") }
    func setActivationPolicy(_ policy: PermissionActivationPolicy) { calls.append("policy:\(policy)") }
    func showGuideWindow() { calls.append("showGuide") }
    func updateGuideWindow() { calls.append("updateGuide") }
    func closeGuideWindow() { calls.append("closeGuide") }
    func openAccessibilitySettings() { calls.append("openSettings") }
    func openApplicationsFolder() { calls.append("openApplications") }
    func startWatchdog() { calls.append("startWatchdog") }
    func stopWatchdog() { calls.append("stopWatchdog") }
    func freezeLiftSnapshots() { calls.append("freezeLift") }
    func unfreezeLiftSnapshots() { calls.append("unfreezeLift") }
    func restoreLiftedWindows(episode: UInt64) async { calls.append("restoreLiftedWindows") }
    func suspendPanelsAndStores() { calls.append("suspendPanelsAndStores") }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        calls.append("launchNewInstance")
        return launchResult
    }
    func terminateSelf() { calls.append("terminateSelf") }
}

private final class PermissionSpy {
    var trusted: Bool
    private(set) var promptCount = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    var service: PermissionService {
        PermissionService(
            trustCheck: { self.trusted },
            promptRequest: {
                self.promptCount += 1
                return self.trusted
            },
            readOnlyVolumeCheck: { _ in false }
        )
    }
}
