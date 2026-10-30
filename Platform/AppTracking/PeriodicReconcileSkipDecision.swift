import CoreGraphics
import Foundation

/// 周期对账（5s tick）的 per-pid 跳读门控。**全部条件满足才允许跳过**该 pid 的 AX 读，任何一条
/// 不满足都强制全读；跳过的一轮遵循既有 `.unread` 语义（座位、缺席时钟、影子池、phantom 状态
/// 一律保持不推进）。条件与理由（护栏，动任何一条前先读 `Docs/26`）：
/// - `captureFailed`：本轮 CG 捕获失败 → 「没变化」无从谈起，强制全读（Docs/26 硬约束）。
/// - `neverRead`：该 pid 还没有成功全读过。
/// - `refreshDue`：距上次成功全读 ≥ `maxSkipInterval`（单调时钟）——无事件且 CG 不变的
///   静默漂移兜底（已知唯一真实案例是原生标签切换，只发生在前台、由 2Hz 前台轮询覆盖）。
/// - `observerInactive`：该 pid 的 AXObserver 没建起来（AXObserverCreate 可能失败），
///   没有事件覆盖就永不跳。
/// - `subscriptionIncomplete`: some seat's per-window notifications are not all registered
///   (`WindowSubscriptionLedger.isCovered`), so events do not cover it either; reading keeps the
///   subscription retries moving in a quiet app instead of waiting for `refreshDue`.
/// - `lastReadUnread`：上次读挂了，必须重试。
/// - `dirtyEvents`：自上次成功全读起有该 pid 的 AX/workspace 事件。
/// - `cgSetChanged`：该 pid 的 CG layer-0 窗口 id 集变了（真关闭/新窗口/切标签必改 CG 集）。
/// - `absenceClockRunning`：有座位在跑缺席时钟（minAbsentSince）——phantom 证据必须按原
///   5s 节奏采样，跳读会拖慢自愈。
/// - `phantomCandidate`：有 everSeenVisible == false 的座位——它可能在没有任何事件的情况下
///   开启缺席 episode，强制读保证 phantom 自愈时延与改造前完全一致（≤ 10s grace + 5s tick）。
/// - `lastRoundChanged`：上一轮落地座位签名或影子池有变 → 收敛未完成，继续连读。
/// - `seatOnScreenChanged`: a seated window went on- or off-screen since the last full read. A window
///   an app hides without any AX notification changes neither the CG id set nor the dirty flag; this
///   is what lets the absence fallback (`AbsentSeatReleaseDecision`) notice it within one tick.
enum PeriodicReconcileSkipDecision {
    static let defaultMaxSkipInterval: TimeInterval = 30

    struct Input {
        var captureFailed: Bool
        var currentCGIDs: Set<CGWindowID>
        /// 上次成功全读时该 pid 的 CG 窗口 id 集；nil = 还没读过。
        var lastObservedCGIDs: Set<CGWindowID>?
        var dirtySinceLastRead: Bool
        var hasAbsenceClock: Bool
        var hasPhantomCandidate: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
        var observerActive: Bool
        var allSeatsSubscribed: Bool
        var uptimeSinceLastFullRead: TimeInterval
        var maxSkipInterval: TimeInterval = PeriodicReconcileSkipDecision.defaultMaxSkipInterval
        var seatOnScreenChanged: Bool = false
    }

    enum Reason: String, Equatable {
        case captureFailed
        case neverRead
        case refreshDue
        case observerInactive
        case subscriptionIncomplete
        case lastReadUnread
        case dirtyEvents
        case cgSetChanged
        case absenceClockRunning
        case phantomCandidate
        case lastRoundChanged
        case seatOnScreenChanged
    }

    enum Verdict: Equatable {
        case fullRead(Reason)
        case skip
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.captureFailed { return .fullRead(.captureFailed) }
        guard let lastObserved = input.lastObservedCGIDs else { return .fullRead(.neverRead) }
        if input.uptimeSinceLastFullRead >= input.maxSkipInterval { return .fullRead(.refreshDue) }
        if !input.observerActive { return .fullRead(.observerInactive) }
        if !input.allSeatsSubscribed { return .fullRead(.subscriptionIncomplete) }
        if input.lastReadWasUnread { return .fullRead(.lastReadUnread) }
        if input.dirtySinceLastRead { return .fullRead(.dirtyEvents) }
        if input.currentCGIDs != lastObserved { return .fullRead(.cgSetChanged) }
        if input.seatOnScreenChanged { return .fullRead(.seatOnScreenChanged) }
        if input.hasAbsenceClock { return .fullRead(.absenceClockRunning) }
        if input.hasPhantomCandidate { return .fullRead(.phantomCandidate) }
        if input.lastRoundChanged { return .fullRead(.lastRoundChanged) }
        return .skip
    }
}
