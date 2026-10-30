import Foundation

/// 补扫（`AppTracker.scanNonAdmittedApps`）的准入纯决策层。
///
/// 补扫负责捡起 seed 时没答上话的 App。它必须遵守两条与 seed 相同的规则，历史上都栽过：
///
/// 1. **准入看的是 eligible 过滤后的集合，不是原始 AX 列表**。原始列表非空 ≠ 有可上任务栏的
///    窗口——透明面板、扩展、系统内部窗口都在 AX 里。误收的代价是永久的：`reconcile()` 只清
///    死进程，**活着但零座位的 `AppEntry` 永不删除**，`rebuildSnapshot` 于是一直投影它的
///    `app-*` 兜底记录，任务栏上留下一张擦不掉的 App 级卡。
/// 2. **过滤动作发生在这里，过滤结果原样交给调用方消费**。如果本类型只收一个
///    `eligibleCount: Int`，那么"生产代码误传 `snaps.count`"这个正是本 bug 的失败模式，单测
///    照样全绿。所以 `prepare` 亲自跑过滤并把 `eligible` 数组带出去，`AppTracker` 直接把它喂给
///    `reconcileSeats(preloadedEligible:)`——顺带也就不会再触发第二次无超时 AX 读。
///
/// 窗口类型走泛型：`AXWindowSnapshot` 含非可选 `AXUIElement`，单测无法凭空构造；泛型让测试用
/// 假窗口类型即可覆盖过滤接线，纯决策层也就不必依赖 ApplicationServices。
enum ScanAdmissionDecision {

    /// 进程代际身份。pid 会被复用：后台探测拿到的 AX element 属于探测那一刻的进程实例，
    /// 回调时必须确认 pid 背后还是同一个实例。`startTime` 来自 POSIX
    /// `ProcessLiveness.startTime(pid:)`（活进程必有值）。
    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startTimeSec: Int64?
        let startTimeUsec: Int32?
        let bundleID: String?

        init(pid: pid_t, startTimeSec: Int64?, startTimeUsec: Int32?, bundleID: String?) {
            self.pid = pid
            self.startTimeSec = startTimeSec
            self.startTimeUsec = startTimeUsec
            self.bundleID = bundleID
        }

        /// 三项全等才算同一进程实例。启动时刻任一侧缺失即判不匹配（保守）：读不到启动时刻
        /// 说明进程已经没了，本就不该收编，等下一轮补扫即可。
        static func matches(probed: Self, current: Self) -> Bool {
            guard probed.pid == current.pid, probed.bundleID == current.bundleID else { return false }
            guard let probedSec = probed.startTimeSec, let currentSec = current.startTimeSec,
                  let probedUsec = probed.startTimeUsec, let currentUsec = current.startTimeUsec
            else { return false }
            return probedSec == currentSec && probedUsec == currentUsec
        }
    }

    /// 一次探测的过滤结果。`eligible` 就是准入后要交给 `reconcileSeats` 的那个集合。
    struct Prepared<Window> {
        let eligible: [Window]
        let rawCount: Int
        let readFailed: Bool
    }

    enum Verdict: Equatable {
        case admit
        case skipNotRegular
        case skipTerminated
        case skipAlreadyTracked
        case skipIdentityMismatch
        case skipUnread
        case skipNoEligible
    }

    /// `rawWindows == nil` 表示这次 AX 读失败（`.unread`）——与"读到 0 个窗口"区分开，前者
    /// 只是没答上话，后者是确实没有窗口。
    static func prepare<Window>(
        rawWindows: [Window]?,
        isEligible: (Window) -> Bool
    ) -> Prepared<Window> {
        guard let rawWindows else {
            return Prepared(eligible: [], rawCount: 0, readFailed: true)
        }
        return Prepared(
            eligible: rawWindows.filter(isEligible),
            rawCount: rawWindows.count,
            readFailed: false
        )
    }

    /// 判定顺序：进程态 → 进程代际 → 读结果 → 合格窗口。
    /// 代际比对在内部完成（不接 `identityMatches: Bool`，那种入参一样会被误传）。
    static func verdict<Window>(
        _ prepared: Prepared<Window>,
        probedIdentity: ProcessIdentity,
        currentIdentity: ProcessIdentity,
        isRegularNonSelf: Bool,
        isTerminated: Bool,
        alreadyTracked: Bool
    ) -> Verdict {
        if !isRegularNonSelf { return .skipNotRegular }
        if isTerminated { return .skipTerminated }
        if alreadyTracked { return .skipAlreadyTracked }
        if !ProcessIdentity.matches(probed: probedIdentity, current: currentIdentity) {
            return .skipIdentityMismatch
        }
        if prepared.readFailed { return .skipUnread }
        if prepared.eligible.isEmpty { return .skipNoEligible }
        return .admit
    }
}
