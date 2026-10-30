import Foundation

// MARK: - 安装位置

/// 当前这份应用副本所在的位置。
///
/// macOS 的辅助功能授权绑在**具体的应用副本**上。跑在只读卷（挂载的磁盘映像）或
/// App Translocation 临时路径上的副本，用户就算在系统设置里打了勾也永远不会生效——
/// 授权记录指向的是一份卸载/退出就消失的副本。所以这两种位置要先请用户搬家，
/// 而且**绝不能**向 TCC 发起注册请求，免得在系统里留下一条指向临时副本的死记录。
enum AppInstallLocation: String, Equatable {
    case applications
    case readOnlyVolume
    case appTranslocation
    case other

    /// - Parameter isReadOnlyVolume: 返回 `nil` 表示读不到卷信息（卷刚被卸载之类）。
    ///   这时一律按可写处理——宁可漏拦，也不要把位置正常的用户锁死在搬家页上。
    init(bundleURL: URL, isReadOnlyVolume: (URL) -> Bool?) {
        let url = bundleURL.standardizedFileURL
        let path = url.path

        if path.split(separator: "/").contains("AppTranslocation") {
            self = .appTranslocation
        } else if Self.isUnderApplications(path) {
            self = .applications
        } else if isReadOnlyVolume(url) == true {
            self = .readOnlyVolume
        } else {
            self = .other
        }
    }

    private static func isUnderApplications(_ path: String) -> Bool {
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// 临时位置绝不允许向 TCC 注册。
    var allowsAccessibilityPrompt: Bool { !isTransient }

    /// 临时副本只当一次性引导壳：不接管其他实例、不注册全局热键、不请求权限。
    var isTransient: Bool {
        switch self {
        case .readOnlyVolume, .appTranslocation:
            return true
        case .applications, .other:
            return false
        }
    }
}

// MARK: - 引导步骤

/// 引导页当前该显示哪一步。
///
/// ⚠️ `.stalled` 只表示「等了很久还没拿到权限，该给排障建议了」，**不是**
/// 「系统里的旧授权记录已经失效」的判定——TCC 数据库读不到，我们既无法证明
/// 用户到底有没有打开开关，也无法证明旧记录失配。基于它的文案必须一律是条件式的。
enum PermissionOnboardingState: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case granted

    static func initial(installLocation: AppInstallLocation, isTrusted: Bool) -> Self {
        // 位置判定优先于受信判定：临时副本即使当前受信，那份授权也会随副本消失。
        guard installLocation.allowsAccessibilityPrompt else {
            return .moveToApplications(installLocation)
        }
        return isTrusted ? .granted : .waiting
    }

    func updated(isTrusted: Bool, elapsed: TimeInterval, stallAfter: TimeInterval) -> Self {
        if case .moveToApplications = self { return self }
        if isTrusted { return .granted }
        return elapsed >= stallAfter ? .stalled : .waiting
    }
}

// MARK: - 运行期丢失防抖

/// 运行期权限丢失的防抖判定。
///
/// 它只决定**用户可见的停运时机**（收起任务条、弹恢复引导）。
/// 最大化避让的快照保护**不靠它**：有会话/待还原状态时那边仍每 0.2s 轮询一次，
/// 这里 5s 一次，中间的空窗由 `WindowLiftAvoidanceController` 在 `poll()` 里自检兜住。
struct PermissionLossDetector: Equatable {
    enum Verdict: Equatable {
        /// 权限正常。
        case stable
        /// 读到一次 false。用户无感，但要立刻冻结窗口快照。
        case uncertain
        /// 确认丢失：连续读到 false，且已经持续够久。
        case lost
    }

    /// 判定丢失需要的最短持续时间。等于看门狗的一个轮询周期——
    /// 光看「连续两次」不够：定时器 tick 和 `applicationDidBecomeActive`
    /// 可能在几十毫秒内连着来两次，那不足以证明权限真的没了。
    static let minimumSustained: TimeInterval = 5

    private var firstFalseAt: TimeInterval?
    private var consecutiveFalse = 0

    init() {}

    /// - Parameter at: **单调**时钟（`ProcessInfo.processInfo.systemUptime`），不是墙钟。
    mutating func record(trusted: Bool, at: TimeInterval) -> Verdict {
        guard !trusted else {
            firstFalseAt = nil
            consecutiveFalse = 0
            return .stable
        }

        // 锚点只在第一次 false 时落一次：乱序/提前到达的采样不许把它往回拨，
        // 否则一串抖动的采样会把「已经持续了多久」无限重置。
        if firstFalseAt == nil { firstFalseAt = at }
        consecutiveFalse += 1

        let elapsed = max(0, at - (firstFalseAt ?? at))
        if consecutiveFalse >= 2, elapsed >= Self.minimumSustained { return .lost }
        return .uncertain
    }
}

// MARK: - 系统设置入口

enum AccessibilitySettingsLink {
    /// 「隐私与安全性 → 辅助功能」深链。`AppDelegate` 和状态菜单共用这一处，
    /// 别再各自抄一份字符串。
    static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
