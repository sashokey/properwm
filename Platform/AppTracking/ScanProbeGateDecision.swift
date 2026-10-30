import CoreGraphics
import Foundation

/// `scanNonAdmittedApps()` 的 per-候选探测门控。改造前每个「永远不会被准入」的后台常规 app
/// 每 5 秒都要吃一次 100ms 超时的 AX 探测、永不停歇；本门控用两个免费判据把稳态探测降到零：
/// - **CG 在场判据**：候选在本 tick CG 全表（layer-0，含最小化/隐藏/其它 Space）没有任何窗口
///   → 没有可准入之物（座位创建必须有可解析的 cgWindowID），跳过。
/// - **记忆判据**：上次探测结论是「无合格窗口」、进程代际未变、CG 窗口集也没变 → 结论仍然
///   成立，跳过。`.unread`（挂死 app）**永不记忆**，保持原 5s 重试。
/// 三个强制探测的兜底优先于一切跳过：CG 捕获失败（失败与空集不可区分，Docs/26 硬约束）、
/// 60s 慢速全扫到期（封住任何门控漏洞）、workspace 启动通知置脏。
/// 启动后的 0.5/1/2/4s 四轮补扫完全绕过本门控（不传 tick 快照即旁路）。
enum ScanProbeGateDecision {
    static let defaultFullScanInterval: TimeInterval = 60

    struct Memo: Equatable {
        var identity: ScanAdmissionDecision.ProcessIdentity
        var lastCGIDs: Set<CGWindowID>
        var verdictWasNoEligible: Bool
    }

    struct Input {
        var captureFailed: Bool
        var cgWindowIDs: Set<CGWindowID>
        var memo: Memo?
        var currentIdentity: ScanAdmissionDecision.ProcessIdentity
        var workspaceDirty: Bool
        var slowFullScanDue: Bool
    }

    enum Reason: String, Equatable {
        case captureFailed
        case fullScanDue
        case workspaceDirty
        case noMemo
        case identityChanged
        case cgSetChanged
        case memoNotConclusive
    }

    enum Verdict: Equatable {
        case probe(Reason)
        case skipNoCGWindows
        case skipMemoized
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.captureFailed { return .probe(.captureFailed) }
        if input.slowFullScanDue { return .probe(.fullScanDue) }
        if input.workspaceDirty { return .probe(.workspaceDirty) }
        if input.cgWindowIDs.isEmpty { return .skipNoCGWindows }
        guard let memo = input.memo else { return .probe(.noMemo) }
        guard ScanAdmissionDecision.ProcessIdentity.matches(
            probed: memo.identity,
            current: input.currentIdentity
        ) else { return .probe(.identityChanged) }
        if memo.lastCGIDs != input.cgWindowIDs { return .probe(.cgSetChanged) }
        guard memo.verdictWasNoEligible else { return .probe(.memoNotConclusive) }
        return .skipMemoized
    }
}
