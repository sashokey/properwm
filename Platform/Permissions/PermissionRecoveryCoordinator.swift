import Combine
import Foundation

/// 后台权限探针的代次与单次在飞门控。`stop()` 会让已经发出的结果永久失效；
/// 下一次 `start()` 即使先发出新探针，也不会被旧回调清掉在飞状态。
///
/// **已知代价**：`beginProbe()` 在上一次探针还没回来时返回 nil，这一拍的采样**被整个丢弃**。
/// `AXIsProcessTrusted()` 改到后台队列执行之后，5 秒一次的采样不再保证每拍都有结果。
/// `PermissionLossDetector` 按单调时间判「连续两次 false ≥ 5s」，丢样本**不会导致误判**
/// （不会把还有权限判成丢失），但会**推迟**权限丢失的发现。这是刻意接受的：
/// 采样本身若拖住主线程，代价是每次菜单/交互都被顶一下，比晚几秒发现权限丢失更糟。
/// 真正保护已托举窗口的不是这条看门狗，是 `WindowLiftAvoidanceController` 在存在
/// 会话/待还原状态时保持的 0.2 秒自检；1 秒慢档只用于没有快照的空闲期。
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

/// 状态机声明出来的副作用由谁去做。全部走协议，好让状态机的副作用序列可以单测。
///
/// 「起/停一次授权过程」「重新检测」「取消恢复任务」不在这里——那几件事是协调器
/// 自己的账（它持有 model 与 `recoveryTask`），不该外包出去。
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
    func releaseHotKey()
    func registerHotKey()
    func launchNewInstance(episode: UInt64) async -> Result<Void, Error>
    func terminateSelf()
}

/// 权限引导与恢复的唯一真相源。视图只观察 `presentation`。
@MainActor
final class PermissionRecoveryCoordinator: ObservableObject {
    /// 视图唯一的数据源。`nil` = 不该有引导窗口。
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

    /// 事件队列 + 重入闸门：`startPolling()` 可能同步就确认了授权并回调，
    /// 那会在上一批副作用还没执行完时再次进入状态机。排队处理，顺序才是确定的。
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

    // MARK: - 入口

    func launched(trusted: Bool) {
        dispatch(.launched(location: installLocation, trusted: trusted))
    }

    /// 看门狗每次采样都喂进来。防抖判定在纯 `PermissionLossDetector` 里。
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

    // MARK: - 派发

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
            case .releaseHotKey:
                handler?.releaseHotKey()
            case .registerHotKey:
                handler?.registerHotKey()
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

    // MARK: - 授权过程（每 episode 一个 model）

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

    // MARK: - 恢复链（任务归协调器所有，终止时取消）

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
