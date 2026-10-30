import Foundation

/// LauncherChip 的**纯视觉决策层**：给定运行态，产出图标下方要不要画运行小圆点。
/// 抽成纯逻辑是为了可单测，渲染副作用留在 LauncherChip。
///
/// 这个类型只剩一条判断，但**它承载的信号现在是唯一的**：owner 2026-08-02 拿掉了按状态
/// 淡化图标（浅深两色一起，理由见 `Docs/27-product-decisions.md`），所以「这个应用还在不在」
/// 完全靠有没有这颗点表达——运行=有点，退出=无点，与所在分区（消息区 / 抽屉 / 保留图标）无关。
/// 「运行但隐藏 / 最小化」不再有任何图标级表现，是明确接受的代价。
enum LauncherChipVisualPlan {
    struct Visual: Equatable {
        let showsRunningDot: Bool
    }

    static func visual(isRunning: Bool) -> Visual {
        Visual(showsRunningDot: isRunning)
    }
}
