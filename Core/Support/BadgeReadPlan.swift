import Foundation

/// 角标轮询每 tick 的读取计划（纯决策）。产品硬约束：**可见状态下节奏保持 0.5s 不变**——
/// 本类型只决定这一 tick「读什么、怎么读」，从不拉长间隔：
/// - `pause`：没有可读的消息应用（可见 ∩ 在跑为空）或任务条逻辑隐藏 → 本 tick 零 AX 流量。
///   恢复条件出现后由调用方**立即读一次**（零感知门控，看板卡「没有消息应用时暂停角标轮询」）。
/// - `fullWalk`：需要重建 Dock 项元素缓存（无缓存 / 被请求重走 / 10s 自愈到期——自愈兜住
///   Dock 图标钉住、重排这类没有错误信号的病理情形，最坏陈旧上界即 10s）。
/// - `targeted`：走缓存元素定点读（1~3 次 AX 往返，替代整棵 Dock 树的 25~45 次）。
enum BadgeReadPlan {
    static let defaultFullWalkInterval: TimeInterval = 10

    struct Input {
        /// 本 tick 需要读角标的应用：消息区可见 **∩** 在跑（kept 但没跑的没有 Dock 磁贴）。
        var messagingBundleIDs: [String]
        var taskbarVisible: Bool
        var hasCache: Bool
        var cacheAgeSeconds: TimeInterval
        var rewalkRequested: Bool
        var fullWalkInterval: TimeInterval = BadgeReadPlan.defaultFullWalkInterval
    }

    enum WalkReason: String, Equatable {
        case noCache
        case rewalkRequested
        case selfHealDue
    }

    enum Verdict: Equatable {
        case pause
        case fullWalk(WalkReason)
        case targeted([String])
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.messagingBundleIDs.isEmpty || !input.taskbarVisible { return .pause }
        if !input.hasCache { return .fullWalk(.noCache) }
        if input.rewalkRequested { return .fullWalk(.rewalkRequested) }
        if input.cacheAgeSeconds >= input.fullWalkInterval { return .fullWalk(.selfHealDue) }
        return .targeted(input.messagingBundleIDs)
    }
}
