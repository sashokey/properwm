import Foundation

// MARK: - 输入输出

enum PermissionActivationPolicy: Equatable {
    /// 无程序坞图标的常规运行态。
    case accessory
    /// 普通应用：引导窗口需要被带到前台时才用。
    case regular
}

enum PermissionEpisodePurpose: Equatable {
    case initialLaunch
    case runtimeRecovery
}

/// 权限相关的整体阶段。
///
/// 每次进入「等待授权」都会分配一个新的 `episode`，异步完成回来时要带着它——
/// 只设置阶段挡不住已经在 `await` 里的任务（`applicationShouldTerminate` 返回
/// `.terminateLater` 期间事件循环还在跑），代次不匹配的回调必须被丢弃。
enum PermissionPhase: Equatable {
    case idle
    /// 临时副本（只读卷 / App Translocation）的一次性引导壳，终态。
    case transientShell(AppInstallLocation)
    case onboarding(episode: UInt64)
    case running
    /// 看门狗读到第一次 false。用户界面无变化，但窗口快照已冻结。
    case uncertain
    case suspended(episode: UInt64)
    case restoringWindows(episode: UInt64)
    case relaunching(episode: UInt64)
    case relaunchFailed(episode: UInt64, message: String)
    case terminating
}

enum PermissionEvent: Equatable {
    case launched(location: AppInstallLocation, trusted: Bool)
    case trustVerdict(PermissionLossDetector.Verdict)
    case grantObserved(episode: UInt64)
    case windowsRestored(episode: UInt64)
    case relaunchSucceeded(episode: UInt64)
    case relaunchFailed(episode: UInt64, message: String)
    case retryRequested
    case recheckRequested
    case quitRequested
    case terminationRequested
}

enum PermissionEffect: Equatable {
    case startApp
    case setActivationPolicy(PermissionActivationPolicy)
    case showGuide
    case updateGuide
    case closeGuide
    case startPermissionEpisode(purpose: PermissionEpisodePurpose, episode: UInt64)
    case stopPermissionEpisode
    case requestSystemPrompt
    case recheckNow
    case startWatchdog
    case stopWatchdog
    case freezeLift
    case unfreezeLift
    case restoreLiftedWindows(episode: UInt64)
    case suspendPanelsAndStores
    case releaseHotKey
    case registerHotKey
    case launchNewInstance(episode: UInt64)
    case cancelRecoveryTask
    case terminateSelf
}

/// 引导窗口要显示的内容。`nil` 表示不该有窗口。
///
/// 首次授权和运行期恢复的排障文案**必须分开**：首次授权成功是当前进程直接继续
/// `startApp()`，既没有「自动重启」，也不存在本轮被抬起的窗口残留。
enum PermissionPresentation: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case recoveryWaiting
    case recoveryStalled
    case restoringWindows
    case relaunching
    case relaunchFailed(message: String)
}

// MARK: - 状态机

/// 纯状态机：不碰 AppKit，副作用只以 `PermissionEffect` 的形式返回，由协调器执行。
struct PermissionRecoveryMachine: Equatable {
    private(set) var phase: PermissionPhase = .idle
    private var episodeCounter: UInt64 = 0

    init() {}

    mutating func handle(_ event: PermissionEvent) -> [PermissionEffect] {
        // 终态吞掉一切：一旦决定退出，任何迟到的恢复事件都不许再拉起新实例。
        if case .terminating = phase { return [] }

        switch event {
        case .terminationRequested:
            phase = .terminating
            return [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode]

        case .quitRequested:
            phase = .terminating
            return [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode, .terminateSelf]

        case let .launched(location, trusted):
            return handleLaunched(location: location, trusted: trusted)

        case let .trustVerdict(verdict):
            return handleTrustVerdict(verdict)

        case let .grantObserved(episode):
            return handleGrantObserved(episode: episode)

        case let .windowsRestored(episode):
            guard case let .restoringWindows(current) = phase, current == episode else { return [] }
            phase = .relaunching(episode: current)
            return [.updateGuide, .releaseHotKey, .launchNewInstance(episode: current)]

        case let .relaunchSucceeded(episode):
            guard case let .relaunching(current) = phase, current == episode else { return [] }
            return [.terminateSelf]

        case let .relaunchFailed(episode, message):
            guard case let .relaunching(current) = phase, current == episode else { return [] }
            phase = .relaunchFailed(episode: current, message: message)
            // 拉新实例失败时旧实例要继续活着，热键得还回来。
            return [.registerHotKey, .updateGuide]

        case .retryRequested:
            guard case let .relaunchFailed(current, _) = phase else { return [] }
            phase = .relaunching(episode: current)
            // 重试同样要先释放热键，不能因为「上次已经释放过」就跳过——
            // 失败分支已经把它重新注册回来了。
            return [.updateGuide, .releaseHotKey, .launchNewInstance(episode: current)]

        case .recheckRequested:
            switch phase {
            case .onboarding, .suspended:
                return [.recheckNow]
            default:
                return []
            }
        }
    }

    private mutating func handleLaunched(
        location: AppInstallLocation,
        trusted: Bool
    ) -> [PermissionEffect] {
        guard case .idle = phase else { return [] }

        if location.isTransient {
            // 临时副本：不请求权限（免得往 TCC 里写一条指向临时副本的死记录），
            // 也不轮询——它待在这个位置就永远不可能真正拿到权限。
            phase = .transientShell(location)
            return [.setActivationPolicy(.regular), .showGuide]
        }

        if trusted {
            phase = .running
            return [.setActivationPolicy(.accessory), .startApp, .startWatchdog]
        }

        let episode = nextEpisode()
        phase = .onboarding(episode: episode)
        return [
            .setActivationPolicy(.regular),
            .showGuide,
            .startPermissionEpisode(purpose: .initialLaunch, episode: episode),
            .requestSystemPrompt,
        ]
    }

    private mutating func handleTrustVerdict(
        _ verdict: PermissionLossDetector.Verdict
    ) -> [PermissionEffect] {
        switch verdict {
        case .stable:
            guard case .uncertain = phase else { return [] }
            phase = .running
            return [.unfreezeLift]

        case .uncertain:
            guard case .running = phase else { return [] }
            phase = .uncertain
            return [.freezeLift]

        case .lost:
            switch phase {
            case .running, .uncertain:
                let episode = nextEpisode()
                phase = .suspended(episode: episode)
                return [
                    .stopWatchdog,
                    // `.running` 直接跳到 `.lost` 时还没冻结过；冻结是幂等的。
                    .freezeLift,
                    .suspendPanelsAndStores,
                    .setActivationPolicy(.regular),
                    .showGuide,
                    .startPermissionEpisode(purpose: .runtimeRecovery, episode: episode),
                    // `tccutil reset` 之后本实例可能已经不在辅助功能列表里了，
                    // 光轮询用户根本没有东西可勾——必须重新注册一次。
                    .requestSystemPrompt,
                ]
            default:
                return []
            }
        }
    }

    private mutating func handleGrantObserved(episode: UInt64) -> [PermissionEffect] {
        switch phase {
        case let .onboarding(current) where current == episode:
            phase = .running
            return [
                .stopPermissionEpisode,
                .closeGuide,
                .setActivationPolicy(.accessory),
                .startApp,
                .startWatchdog,
            ]

        case let .suspended(current) where current == episode:
            // 还原推迟到这一刻：权限刚回来，AX 才写得动被抬起的窗口。
            phase = .restoringWindows(episode: current)
            return [.stopPermissionEpisode, .updateGuide, .restoreLiftedWindows(episode: current)]

        default:
            return []
        }
    }

    private mutating func nextEpisode() -> UInt64 {
        episodeCounter &+= 1
        return episodeCounter
    }

    // MARK: 展示态

    static func presentation(
        phase: PermissionPhase,
        onboarding: PermissionOnboardingState
    ) -> PermissionPresentation? {
        switch phase {
        case .idle, .running, .uncertain, .terminating:
            return nil

        case let .transientShell(location):
            return .moveToApplications(location)

        case .onboarding:
            switch onboarding {
            case let .moveToApplications(location): return .moveToApplications(location)
            case .waiting, .granted: return .waiting
            case .stalled: return .stalled
            }

        case .suspended:
            switch onboarding {
            case let .moveToApplications(location): return .moveToApplications(location)
            case .waiting, .granted: return .recoveryWaiting
            case .stalled: return .recoveryStalled
            }

        case .restoringWindows:
            return .restoringWindows

        case .relaunching:
            return .relaunching

        case let .relaunchFailed(_, message):
            return .relaunchFailed(message: message)
        }
    }
}
