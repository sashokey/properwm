import Foundation

/// 卡片标签对窗口标题的「跟随抑制」（2026-09-18）。
///
/// 网页会自己反复改 `document.title`（OA 系统的新消息闪烁、轮播），浏览器窗口标题就每秒横跳一次；
/// 卡片老实跟着换字、变宽变窄，把右边整条卡推来推去（用户录屏 44 秒没停）。清单层必须照实上报
/// 标题（窗口识别、标签组折叠都靠它），所以抑制只发生在**渲染标签**这一层：
/// - 标题变了照常立刻跟：导航、切标签页不能有延迟；
/// - 同一张卡在 `memoryWindow` 内第 `flipThreshold + 1` 次变化起判为横跳，标签**冻结在当前显示的那份**；
/// - 原始标题安静满 `quietInterval` 才放开，一次换到最新值。
/// 纯状态机，时钟由调用方注入；`AppRuntime` 拿输出覆盖投影层的标签，悬停气泡与菜单仍显示原始标题。
struct WindowTitleSettle {
    struct Policy: Equatable {
        /// 数变化次数的滑动窗口。
        var memoryWindow: TimeInterval = 6
        /// 窗口内允许照常跟随的变化次数；超过即冻结。
        var flipThreshold: Int = 3
        /// 原始标题连续多久不变才放开冻结。
        var quietInterval: TimeInterval = 2
    }

    private struct Entry {
        var displayed: String
        var raw: String
        var lastChangeAt: TimeInterval
        var changeTimes: [TimeInterval]
    }

    let policy: Policy
    private var entries: [String: Entry] = [:]

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// 喂一轮当前标题（卡 id → 原始标题），返回**被冻结**的卡（id → 该显示的标题）。
    /// 没出现在输入里的卡即刻遗忘；新出现的卡以当前标题起步。
    mutating func observe(rawTitles: [String: String], now: TimeInterval) -> [String: String] {
        entries = entries.filter { rawTitles[$0.key] != nil }
        var held: [String: String] = [:]
        for (id, raw) in rawTitles {
            guard var entry = entries[id] else {
                entries[id] = Entry(displayed: raw, raw: raw, lastChangeAt: now, changeTimes: [])
                continue
            }
            if raw != entry.raw {
                entry.raw = raw
                entry.lastChangeAt = now
                entry.changeTimes.removeAll { $0 < now - policy.memoryWindow }
                entry.changeTimes.append(now)
                if entry.changeTimes.count <= policy.flipThreshold { entry.displayed = raw }
            } else if entry.displayed != raw, now - entry.lastChangeAt >= policy.quietInterval {
                entry.displayed = raw
            }
            entries[id] = entry
            if entry.displayed != entry.raw { held[id] = entry.displayed }
        }
        return held
    }

    /// 最早一张冻结卡可以放开的时刻；没有冻结 → nil。调用方到点再 `observe` 一次。
    var nextReleaseAt: TimeInterval? {
        entries.values
            .filter { $0.displayed != $0.raw }
            .map { $0.lastChangeAt + policy.quietInterval }
            .min()
    }
}
