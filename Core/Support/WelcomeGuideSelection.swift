import Foundation

/// 首次引导那一屏三个勾选框的状态。
///
/// 默认全勾（`recommended`）。三条同属「把系统 Dock 让给钨极」这一件事，但**允许分开勾**：
/// 这是在写别人的系统偏好，该给用户拒绝其中某一条的余地（owner 2026-08-28 定）。
struct WelcomeGuideSelection: Equatable {
    var hidesDock: Bool
    var usesScaleMinimizeEffect: Bool
    var minimizesIntoAppIcon: Bool

    static let recommended = WelcomeGuideSelection(
        hidesDock: true,
        usesScaleMinimizeEffect: true,
        minimizesIntoAppIcon: true
    )

    var isEmpty: Bool { !hidesDock && !usesScaleMinimizeEffect && !minimizesIntoAppIcon }
}

/// 一次推荐设置写入要动哪几项。`autoHideDelay == nil` 表示**完全不碰** `autohide` /
/// `autohide-delay`——不是「写个默认值」，两者对四象限回读的含义完全不同。
struct NativeDockRecommendations: Equatable {
    var autoHideDelay: Double?
    var minimizeEffectScale: Bool
    var minimizeIntoAppIcon: Bool

    var isEmpty: Bool { autoHideDelay == nil && !minimizeEffectScale && !minimizeIntoAppIcon }
}

extension WelcomeGuideSelection {
    /// 勾选 → 要写哪几个键。**这一步是整条链上最容易把两个最小化选项接反的地方**，所以独立成
    /// 纯函数并单测（`WelcomeGuideDecisionTests`）；只测 `NativeDockRecommendations` 抓不到接反。
    ///
    /// - Parameter hideDelay: 勾了「隐藏系统 Dock」时落哪一档，由调用方传
    ///   `AppSettingsStore.neverWakeDelay`——Core 不该认识 App 层的常量。
    func recommendations(hideDelay: Double) -> NativeDockRecommendations {
        NativeDockRecommendations(
            autoHideDelay: hidesDock ? hideDelay : nil,
            minimizeEffectScale: usesScaleMinimizeEffect,
            minimizeIntoAppIcon: minimizesIntoAppIcon
        )
    }
}
