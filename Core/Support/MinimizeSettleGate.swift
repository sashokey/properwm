import Foundation

/// 同窗口「minimize → activate」连点的沉降判定(v2,2026-08-25)。
///
/// v1(时间闸:0.65s 沉降地板 + 1.0s 上限)被 owner 实测否决:①地板毁掉「genie 中途反向
/// 打断」手感;②访达一次还原实测 887ms,锚 1.0s 过期后点击裸奔,兄弟仍被带出。
///
/// v2 语义:**确认即放,安全不靠等待**。快照确认 `.minimized` = minimize 写已在目标 App
/// 落地(与并发执行中的 minimize 有了写顺序证明)→ 立即放行;执行层拿着 `dispatchPrior`
/// 先验强制走还原分支(07-05 v3 序,5/5 实测安全;对未最小化窗口写 unminimize 是无害空操作)、
/// 跳过 earlyFocus、封死 app 级兜底——「窗口屏外时先切前台」的三条提拔路径全部堵死,
/// unminimize 落在 genie 中段即反向打断动画(手感来源)。
enum MinimizeSettleGate {
    enum Verdict: Equatable {
        case dispatchNow
        case hold(until: Date)
    }

    /// 未确认时的扣留上限:minimize 真失败时第二击最多死这么久,到点照放(执行层仍带先验)。
    static let maxHold: TimeInterval = 1.0
    /// 先验窗口(锚的第二寿命):minimize 派发后这么久之内的 activate 都带「强制 knownMinimized
    /// + 跳过 earlyFocus + 封死 app 兜底」先验。取 2.0s ≈ 实测最坏动画(访达 887ms)×2 +
    /// 快照回传余量;先验零代价(两种世界都安全),所以可以比 hold 上限宽得多。可调常量,
    /// owner 访达风暴验收校准。
    static let priorWindow: TimeInterval = 2.0

    static func verdict(
        requestKind: PlatformActionRequest.ActionKind,
        minimizeDispatchedAt: Date?,
        snapshotConfirmsMinimized: Bool,
        now: Date,
        maxHold: TimeInterval = Self.maxHold
    ) -> Verdict {
        guard requestKind == .activateWindow, let anchor = minimizeDispatchedAt else {
            return .dispatchNow
        }
        let elapsed = now.timeIntervalSince(anchor)
        // 时钟异常(锚在未来)保守放行,回连点旧行为。
        if elapsed < 0 { return .dispatchNow }
        if elapsed >= maxHold { return .dispatchNow }
        // v2 核心:确认即放。快照翻面即写落地证明;动画期的危险分支由先验封死,不再用时间挡。
        if snapshotConfirmsMinimized { return .dispatchNow }
        return .hold(until: anchor.addingTimeInterval(maxHold))
    }

    /// 「强制 knownMinimized + 跳过 earlyFocus + 封死 app 兜底」先验:锚在先验窗口内即成立。
    /// 时钟异常(负 elapsed)不给先验,整体退回旧行为。
    static func dispatchPrior(
        minimizeDispatchedAt: Date?,
        now: Date,
        priorWindow: TimeInterval = Self.priorWindow
    ) -> Bool {
        guard let anchor = minimizeDispatchedAt else { return false }
        let elapsed = now.timeIntervalSince(anchor)
        return elapsed >= 0 && elapsed < priorWindow
    }
}
