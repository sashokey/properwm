import Combine
import Foundation

struct PermissionWatchdogGate {
    private var generation: UInt64 = 0
    private var isProbeInFlight = false

    mutating func start() {
        generation &+= 1
        isProbeInFlight = false
    }

    mutating func stop() {
        generation &+= 1
        isProbeInFlight = false
    }

    mutating func beginProbe() -> UInt64? {
        guard !isProbeInFlight else { return nil }
        isProbeInFlight = true
        return generation
    }

    mutating func completeProbe(generation completedGeneration: UInt64) -> Bool {
        guard completedGeneration == generation, isProbeInFlight else { return false }
        isProbeInFlight = false
        return true
    }
}

@MainActor
protocol PermissionEffectHandler: AnyObject {
    func startApp()
    func setActivationPolicy(_ policy: PermissionActivationPolicy)
    func showGuideWindow()
    func updateGuideWindow()
    func closeGuideWindow()
    func openAccessibilitySettings()
    func openApplicationsFolder()
    func startWatchdog()
    func stopWatchdog()
    func freezeLiftSnapshots()
    func unfreezeLiftSnapshots()
    func restoreLiftedWindows(episode: UInt64) async
    func suspendPanelsAndStores()

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error>
    func terminateSelf()
}

@MainActor
final class PermissionRecoveryCoordinator: ObservableObject {
    @Published private(set) var presentation: PermissionPresentation?

    private weak var handler: PermissionEffectHandler?
    private let permissionService: PermissionService
    private let installLocation: AppInstallLocation
    private let now: () -> TimeInterval
    private let makeModel: (PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel

    private var machine = PermissionRecoveryMachine()
    private var detector = PermissionLossDetector()
    private var model: AccessibilityPermissionModel?
    private var modelSubscription: AnyCancellable?
    private var recoveryTask: Task<Void, Never>?
    private var onboardingState: PermissionOnboardingState = .waiting

    private var pendingEvents: [PermissionEvent] = []
    private var isDispatching = false

    var phase: PermissionPhase { machine.phase }

    init(
        handler: PermissionEffectHandler?,
        permissionService: PermissionService,
        installLocation: AppInstallLocation,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeModel: ((PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel)? = nil
    ) {
        self.handler = handler
        self.permissionService = permissionService
        self.installLocation = installLocation
        self.now = now
        self.makeModel = makeModel ?? { _, _ in
            AccessibilityPermissionModel(
                permissionService: permissionService,
                installLocation: installLocation
            )
        }
    }

    func launched(trusted: Bool) {
        dispatch(.launched(location: installLocation, trusted: trusted))
    }

    func sampleTrust(_ trusted: Bool) {
        dispatch(.trustVerdict(detector.record(trusted: trusted, at: now())))
    }

    func applicationDidBecomeActive() {
        model?.applicationDidBecomeActive()
    }

    func recheck() { dispatch(.recheckRequested) }
    func retryRelaunch() { dispatch(.retryRequested) }
    func quit() { dispatch(.quitRequested) }
    func terminationRequested() { dispatch(.terminationRequested) }
    func openSettings() { handler?.openAccessibilitySettings() }
    func openApplications() { handler?.openApplicationsFolder() }

    private func dispatch(_ event: PermissionEvent) {
        pendingEvents.append(event)
        guard !isDispatching else { return }
        isDispatching = true
        defer { isDispatching = false }
        while !pendingEvents.isEmpty {
            run(machine.handle(pendingEvents.removeFirst()))
        }
    }

    private func run(_ effects: [PermissionEffect]) {
        for effect in effects {
            switch effect {
            case .startApp:
                handler?.startApp()
            case let .setActivationPolicy(policy):
                handler?.setActivationPolicy(policy)
            case .showGuide:
                refreshPresentation()
                handler?.showGuideWindow()
            case .updateGuide:
                refreshPresentation()
                handler?.updateGuideWindow()
            case .closeGuide:
                refreshPresentation()
                handler?.closeGuideWindow()
            case let .startPermissionEpisode(purpose, episode):
                startEpisode(purpose: purpose, episode: episode)
            case .stopPermissionEpisode:
                stopEpisode()
            case .requestSystemPrompt:
                model?.requestSystemPromptIfNeeded()
            case .recheckNow:
                model?.checkNow()
            case .startWatchdog:
                detector = PermissionLossDetector()
                handler?.startWatchdog()
            case .stopWatchdog:
                handler?.stopWatchdog()
            case .freezeLift:
                handler?.freezeLiftSnapshots()
            case .unfreezeLift:
                handler?.unfreezeLiftSnapshots()
            case let .restoreLiftedWindows(episode):
                startRestore(episode: episode)
            case .suspendPanelsAndStores:
                handler?.suspendPanelsAndStores()

            case let .launchNewInstance(episode):
                startLaunch(episode: episode)
            case .cancelRecoveryTask:
                recoveryTask?.cancel()
                recoveryTask = nil
            case .terminateSelf:
                handler?.terminateSelf()
            }
        }
        refreshPresentation()
    }

    private func refreshPresentation() {
        let next = PermissionRecoveryMachine.presentation(
            phase: machine.phase,
            onboarding: onboardingState
        )
        if presentation != next { presentation = next }
    }

    private func startEpisode(purpose: PermissionEpisodePurpose, episode: UInt64) {
        stopEpisode()
        let model = makeModel(purpose, episode)
        self.model = model
        onboardingState = model.state
        modelSubscription = model.$state.sink { [weak self] state in
            guard let self else { return }
            self.onboardingState = state
            self.refreshPresentation()
        }
        model.onGranted = { [weak self] in
            self?.dispatch(.grantObserved(episode: episode))
        }
        model.startPolling()
    }

    private func stopEpisode() {
        modelSubscription?.cancel()
        modelSubscription = nil
        model?.onGranted = nil
        model?.stop()
        model = nil
    }

    private func startRestore(episode: UInt64) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else { return }
            await handler.restoreLiftedWindows(episode: episode)
            guard !Task.isCancelled else { return }
            self.dispatch(.windowsRestored(episode: episode))
        }
    }

    private func startLaunch(episode: UInt64) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else { return }
            let result = await handler.launchNewInstance(episode: episode)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                self.dispatch(.relaunchSucceeded(episode: episode))
            case let .failure(error):
                self.dispatch(.relaunchFailed(episode: episode, message: error.localizedDescription))
            }
        }
    }
}
