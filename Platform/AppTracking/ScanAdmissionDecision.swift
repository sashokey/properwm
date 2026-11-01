import Foundation

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
        case skipUnsupportedApplication
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
        isWindowApplication: Bool,
        isTerminated: Bool,
        alreadyTracked: Bool
    ) -> Verdict {
        if !isWindowApplication { return .skipUnsupportedApplication }
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
