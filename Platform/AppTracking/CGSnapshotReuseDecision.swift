import CoreGraphics
import Foundation

/// 事件读路径的 CG 全表复用门控（DOCK_CG_SNAPSHOT_REUSE=0 关闭）。
///
/// 背景：`scheduleEventRead` 的后台任务原本**每次**都拍一张 `.optionAll` 全表（实测 ~1.5ms
/// CPU/次，449 条目环境），而前台 0.5s 轮询每 tick 走这条路——活跃使用时 2Hz × 1.5ms 是
/// 空闲改造后剩余最大的单项。绝大多数 tick 里全表与上一张逐位相同。
///
/// 门法：先拍廉价 on-screen 探针（~0.2ms，`captureOnScreenWindowIDs` 口径）。静态条件全过
/// 且探针集与缓存那轮的探针集一致 → 复用缓存全表；任何一条不过 → 现拍全表并刷新缓存。
/// 切标签/关窗/最小化/换 Space/换屏都改变 on-screen 集，探针当场发现 → 现拍，与关门时逐位
/// 一致。唯一被推迟的是「纯屏外变化且无任何 AX/workspace 事件」（事件有全局代数兜着），
/// 上限 `defaultMaxCacheAge`；5s reconcile 的批量路径永远现拍，不走本门控。
///
/// 顺序硬规则：**先探针、后全拍**。若反过来，探针晚于全拍，两者之间的变化会让「旧全表 +
/// 新探针」入缓存——下一 tick 探针相同、复用到缺变化的全表。先探针则同窗口变化只导致下一
/// tick 多拍一次，保守方向。
enum CGSnapshotReuseDecision {
    /// 缓存有效期上限（秒，单调钟）。年龄在主线程组票时计算，后台 AX 读（≤~0.5s）会让真实
    /// 年龄略大于判定值——上限里已含这层余量，别把它调小到与读耗时同量级。
    static let defaultMaxCacheAge: TimeInterval = 2.0

    enum FreshReason: Equatable {
        case disabled          // 杀开关：连探针都不拍，与关门前逐位一致
        case noCache
        case cachedCaptureFailed
        case cacheExpired
        case eventSinceCache   // 缓存那轮之后有 AX/workspace 事件（全局代数变了）
        case absenceClockRunning
        case phantomCandidate
        case observerInactive  // 该 pid 的 AXObserver 不在 → 事件根本到不了，代数判据失效
        case probeChanged
    }

    /// 静态条件（主线程组票时可知的部分）的裁决。探针比对在后台任务里做（`probeVerdict`）。
    enum PreVerdict: Equatable {
        case captureWithoutProbe          // 杀开关路径
        case captureAndPrime(FreshReason) // 现拍全表，并用同轮探针把缓存链重新接上
        case probeThenCompare
    }

    struct Input: Equatable {
        let reuseEnabled: Bool
        let hasCache: Bool
        let cachedCaptureFailed: Bool
        let cacheAge: TimeInterval
        let generationMatches: Bool
        let hasAbsenceClock: Bool
        let hasPhantomCandidate: Bool
        let observerActive: Bool
    }

    static func preVerdict(_ input: Input) -> PreVerdict {
        guard input.reuseEnabled else { return .captureWithoutProbe }
        guard input.hasCache else { return .captureAndPrime(.noCache) }
        if input.cachedCaptureFailed { return .captureAndPrime(.cachedCaptureFailed) }
        if input.cacheAge >= defaultMaxCacheAge || input.cacheAge < 0 {
            return .captureAndPrime(.cacheExpired)
        }
        if !input.generationMatches { return .captureAndPrime(.eventSinceCache) }
        if input.hasAbsenceClock { return .captureAndPrime(.absenceClockRunning) }
        if input.hasPhantomCandidate { return .captureAndPrime(.phantomCandidate) }
        if !input.observerActive { return .captureAndPrime(.observerInactive) }
        return .probeThenCompare
    }

    enum ProbeVerdict: Equatable {
        case reuse
        case captureAndPrime(FreshReason)
    }

    /// 探针集只与**缓存那轮的探针集**自比。探针口径（onScreenOnly + excludeDesktopElements、
    /// layer-0）与全表里的 on-screen 标志位口径不同，绝不与 `snapshot.onScreenWindowIDs` 混比。
    static func probeVerdict(probe: Set<CGWindowID>, cachedProbe: Set<CGWindowID>) -> ProbeVerdict {
        probe == cachedProbe ? .reuse : .captureAndPrime(.probeChanged)
    }

    /// A cached table may only err toward retention. Its below-normal-layer set is a veto, and the
    /// layer-0 probe cannot see a window leaving that set, so a read that lists such an id must
    /// capture fresh instead of reusing the cache.
    static func cachedLayerVetoApplies(
        axWindowIDs: Set<CGWindowID>,
        cachedBelowNormalLayerIDs: Set<CGWindowID>
    ) -> Bool {
        !axWindowIDs.isDisjoint(with: cachedBelowNormalLayerIDs)
    }
}
