import ApplicationServices
import Foundation

/// 辅助功能权限的 I/O 层。三个入口都可注入，好让引导逻辑脱离系统状态做单测。
///
/// 注意：本文件同时编进 window-lab target，那里没有 `AccessibilityPermissionDecision.swift`，
/// 所以这里只提供「卷是不是只读」这个原始事实，安装位置的分类留给调用方去组合。
struct PermissionService {
    private let trustCheck: () -> Bool
    private let promptRequest: () -> Bool
    private let readOnlyVolumeCheck: (URL) -> Bool?

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        promptRequest: @escaping () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        readOnlyVolumeCheck: @escaping (URL) -> Bool? = PermissionService.systemReadOnlyVolumeCheck
    ) {
        self.trustCheck = trustCheck
        self.promptRequest = promptRequest
        self.readOnlyVolumeCheck = readOnlyVolumeCheck
    }

    func hasRequiredPermissions() -> Bool {
        trustCheck()
    }

    /// 弹系统原生请求框，同时把本应用注册进辅助功能列表。
    /// **只能在稳定安装位置调用**——临时副本调了会在系统里留下一条指向该副本的死记录。
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        promptRequest()
    }

    /// `nil` = 读不到卷信息（卷刚被卸载之类）。
    func isReadOnlyVolume(_ url: URL) -> Bool? {
        readOnlyVolumeCheck(url)
    }

    static func systemReadOnlyVolumeCheck(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
    }
}
