import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    /// 系统那边的登录项列表打不开（只有 macOS 12 的老接口会走到这里）。
    /// 不再表示「系统版本太低」——12 和 13+ 都有各自的接入路径。
    case unsupported
    case off
    case on
    case requiresApproval
}

struct LaunchAtLoginMenuPresentation: Equatable {
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    var showsSettingsItem: Bool

    init(title: String, isEnabled: Bool, isChecked: Bool, showsSettingsItem: Bool) {
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.showsSettingsItem = showsSettingsItem
    }

    init(state: LaunchAtLoginState) {
        switch state {
        case .unsupported:
            title = String(localized: "Open at Login (Unavailable)")
            isEnabled = false
            isChecked = false
            showsSettingsItem = false
        case .off:
            title = String(localized: "Open at Login")
            isEnabled = true
            isChecked = false
            showsSettingsItem = false
        case .on:
            title = String(localized: "Open at Login")
            isEnabled = true
            isChecked = true
            showsSettingsItem = false
        case .requiresApproval:
            title = String(localized: "Open at Login (Pending Approval)")
            isEnabled = true
            isChecked = false
            showsSettingsItem = true
        }
    }
}

enum LaunchAtLoginMenuModel {
    static func requestedEnabledValue(afterSelecting state: LaunchAtLoginState) -> Bool? {
        switch state {
        case .unsupported:
            return nil
        case .off, .requiresApproval:
            return true
        case .on:
            return false
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing {
    func currentState() async -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

/// 真正碰系统的那一层，按系统版本二选一：macOS 13+ 是 `SMAppService`（`ModernLoginItemBackend`），
/// macOS 12 是老的登录项列表（`LegacyLoginItemBackend`）。
///
/// `readState()` 会在 `LaunchAtLoginService` 的后台队列上被调用（菜单路径不许在主线程做系统 I/O），
/// 所以实现不能依赖主线程；`setEnabled` / `openSettings` 仍在主线程被调用。
protocol LaunchAtLoginBackend: Sendable {
    func readState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private let backend: any LaunchAtLoginBackend
    private let readerQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.launch-at-login-reader", qos: .userInitiated)

    init(backend: any LaunchAtLoginBackend = LaunchAtLoginService.systemBackend()) {
        self.backend = backend
    }

    func currentState() async -> LaunchAtLoginState {
        let backend = backend
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: backend.readState())
            }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try backend.setEnabled(enabled)
    }

    func openSystemSettings() {
        backend.openSettings()
    }

    /// 两条路注册的都是**当前正在运行的 bundle**：开发构建上勾选会把登录项钉在 `build/DerivedData/…` 上
    /// （规矩见 `.claude/rules/build-and-release.md`）。
    nonisolated static func systemBackend() -> any LaunchAtLoginBackend {
        if #available(macOS 13.0, *) {
            return ModernLoginItemBackend()
        }
        return LegacyLoginItemBackend(list: SharedFileListLoginItems(), bundleURL: Bundle.main.bundleURL)
    }
}

/// macOS 13+：`SMAppService.mainApp`。`register()` 后可能停在 `.requiresApproval`，
/// 要用户去「系统设置 → 通用 → 登录项与扩展」批准，这不是失败。
@available(macOS 13.0, *)
struct ModernLoginItemBackend: LaunchAtLoginBackend {
    func readState() -> LaunchAtLoginState {
        Self.mapStatus(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .off
        @unknown default:
            return .off
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    /// 登录项列表打不开（老接口返回 nil）。
    case unsupported
    /// 插入 / 删除被系统拒绝。
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "Open at Login isn’t available on this Mac.")
        case .writeFailed:
            return String(localized: "Couldn’t update the Login Items list.")
        }
    }
}
