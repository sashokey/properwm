import Combine
import Foundation

/// 一次「等待用户授权」的过程：轮询权限状态、按等待时长推进引导步骤、拿到权限后回调一次。
///
/// ⚠️ **每个 episode 必须新建一个实例。** `didRequestPrompt` 和 `didNotifyGranted` 是
/// 终身一次性门控：首次授权成功之后，同一个实例再也不会弹系统请求框、也不会再回调。
/// 复用它会让「运行期权限丢失 → 恢复」这条路径彻底哑掉。
@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    static let pollInterval: TimeInterval = 1
    static let defaultStallInterval: TimeInterval = 8

    @Published private(set) var state: PermissionOnboardingState

    /// 一次性回调。触发后立即置 nil，避免排队的定时器再喂一次。
    var onGranted: (() -> Void)?
    var onTrustStatusChanged: ((Bool) -> Void)?

    private let permissionService: PermissionService
    private let installLocation: AppInstallLocation
    private let now: () -> TimeInterval
    private let stallAfter: TimeInterval
    private var pollingStartedAt: TimeInterval?
    private var timer: Timer?
    private var didRequestPrompt = false
    private var didNotifyGranted = false
    private var lastObservedTrust: Bool

    init(
        permissionService: PermissionService = PermissionService(),
        installLocation: AppInstallLocation,
        initialTrusted: Bool? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        stallAfter: TimeInterval = AccessibilityPermissionModel.defaultStallInterval
    ) {
        let trusted = initialTrusted ?? permissionService.hasRequiredPermissions()
        self.permissionService = permissionService
        self.installLocation = installLocation
        self.now = now
        self.stallAfter = stallAfter
        self.lastObservedTrust = trusted
        self.state = .initial(installLocation: installLocation, isTrusted: trusted)
    }

    func startPolling() {
        // 临时副本待在那个位置永远拿不到有效授权，轮询没有意义。
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }
        checkNow()
        guard state != .granted, timer == nil else { return }

        // `.common` 模式：菜单跟踪 / 模态期间也要继续走，否则用户开完开关切回来没反应。
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNow() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 弹一次系统原生请求框。临时位置一次都不弹。
    func requestSystemPromptIfNeeded() {
        guard installLocation.allowsAccessibilityPrompt,
              state != .granted,
              !didRequestPrompt else { return }
        didRequestPrompt = true
        permissionService.requestAccessibilityPermission()
    }

    func applicationDidBecomeActive() {
        checkNow()
    }

    func checkNow() {
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }

        let trusted = permissionService.hasRequiredPermissions()
        if trusted != lastObservedTrust {
            lastObservedTrust = trusted
            onTrustStatusChanged?(trusted)
        }

        let elapsed = max(0, now() - (pollingStartedAt ?? now()))
        state = state.updated(isTrusted: trusted, elapsed: elapsed, stallAfter: stallAfter)
        guard state == .granted else { return }

        didNotifyGranted = true
        stop()
        let callback = onGranted
        onGranted = nil
        callback?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
