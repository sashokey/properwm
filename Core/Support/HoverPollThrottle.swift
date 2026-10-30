import Foundation

/// 鼠标移动事件的合并节流（纯决策）。全局/本地 `.mouseMoved` 监视器移动时每秒回调上百次，
/// 而消费方（多屏悬停切换要 350ms 驻留、边缘唤醒热区判定）对 33ms 粒度完全无感。
/// 语义 = leading + trailing：到期事件立即跑；窗口内的事件挂**一个**收尾（移动恰好停在
/// 节流窗口里时，最后一个位置不能丢——热区进出判定靠它）；收尾已挂则丢弃。
struct HoverPollThrottle {
    let minInterval: TimeInterval
    private(set) var lastRunAt: TimeInterval = -.infinity
    private(set) var trailingScheduled = false

    enum Verdict: Equatable {
        case run
        case scheduleTrailing(after: TimeInterval)
        case drop
    }

    mutating func eventArrived(now: TimeInterval) -> Verdict {
        let elapsed = now - lastRunAt
        if elapsed >= minInterval {
            lastRunAt = now
            return .run
        }
        if trailingScheduled { return .drop }
        trailingScheduled = true
        return .scheduleTrailing(after: minInterval - elapsed)
    }

    mutating func trailingFired(now: TimeInterval) {
        trailingScheduled = false
        lastRunAt = now
    }

    /// 监视器被摘除/重装时复位，别让上一段的挂起状态漏进下一段。
    mutating func reset() {
        lastRunAt = -.infinity
        trailingScheduled = false
    }
}
