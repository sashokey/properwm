import Darwin
import Foundation
import Synchronization

/// 进程存活判定的唯一合同（POSIX `kill(pid, 0)`）。
///
/// `AppTracker.reconcile()` 的批量删除路径曾用 `NSRunningApplication(processIdentifier:) == nil`
/// 判死。该 API 解析自 LaunchServices，会对**活**进程瞬时返回 `nil`（实测飞书、Obsidian 等会触发），
/// 导致整个 `AppEntry` 连同其下所有座位被 `reconcile()` 的批量路径一并删掉，绕过逐座位宽限与
/// 幽灵保护。之后 `scanNonAdmittedApps()` 又把同一 pid 以全新座位 token 重新准入，叠加
/// `StripOrderStore` 的 5s 缺席宽限 → 一扇窗出现两张卡。
///
/// 这里只走 POSIX：`kill` 返回 0 即活；返回 -1 且 `errno == ESRCH` 才判死；`EPERM`（进程存在、
/// 但无权限发信号）及其他所有 errno 一律保守判活。**绝不**回退 `NSRunningApplication` /
/// `NSWorkspace` / 其他 LaunchServices 状态。旧脏 worktree 的同名文件在未知 errno 时回退
/// LaunchServices，是错误实现，禁止整包搬运。
///
/// 只依赖 Darwin，不引入 AppKit / ApplicationServices，便于 errno 矩阵单测。
enum ProcessLiveness {
    /// 用 POSIX `kill(pid, 0)` 判定进程是否存活。
    static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return interpret(result: kill(pid, 0), errorCode: errno)
    }

    /// 纯判定函数，供 errno 矩阵单测直接喂入合成值，不发起 syscall：
    /// - `result == 0`：alive
    /// - `result != 0` 且 `errorCode == ESRCH`：dead（无此进程）
    /// - `EPERM` 及 `EINTR` / `EINVAL` / `EAGAIN` 等所有其他 errno：alive（保守判活）
    static func interpret(result: Int32, errorCode: Int32) -> Bool {
        if result == 0 { return true }
        return errorCode != ESRCH
    }

    /// 进程**启动时刻**（`KERN_PROC_PID` sysctl 读 `kinfo_proc.kp_proc.p_starttime`）。
    ///
    /// 用途：pid 会被复用。异步探测期间进程 A 可能退出、pid 被 B 顶替，此时
    /// `isTerminated` / `activationPolicy` 都查不出"实例换人"——`pid + 启动时刻` 才是稳定的
    /// 进程代际身份。**不用 `NSRunningApplication.launchDate`**：它可为 nil，缺失时要么放行
    /// （把旧进程的 AX element 预载给新进程）要么拒收（某些 App 永远进不了补扫），两头都是坑；
    /// sysctl 对活进程一定有值。
    ///
    /// 返回 nil = 进程已不存在（pid 不存在时 sysctl 返回 0 但把 size 置 0，必须查 size）。
    static func startTime(pid: pid_t) -> timeval? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}

/// Values valid for one process generation (`pid` + start time), remembered across LaunchServices
/// hiccups: a pid lookup such as `GetProcessForPID` fails transiently for a live process (the same
/// instant `NSRunningApplication(processIdentifier:)` returns nil), and a value seen earlier stays
/// correct as long as the pid still belongs to the same process. Thread-safe; readers sit on the
/// concurrent action queue. `startTime` is injectable for tests only.
final class ProcessGenerationCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let startTime: timeval
        let value: Value
        let sequence: UInt64
    }

    private struct Storage: Sendable {
        var entries: [pid_t: Entry] = [:]
        var sequence: UInt64 = 0
    }

    private let storage = Mutex(Storage())
    private let capacity: Int
    private let startTime: @Sendable (pid_t) -> timeval?

    init(capacity: Int = 512, startTime: @escaping @Sendable (pid_t) -> timeval? = ProcessLiveness.startTime(pid:)) {
        self.capacity = max(0, capacity)
        self.startTime = startTime
    }

    func remember(_ value: Value, for pid: pid_t) {
        guard capacity > 0 else { return }
        guard let start = startTime(pid) else {
            storage.withLock { $0.entries[pid] = nil }
            return
        }
        if storage.withLock({ $0.entries[pid] == nil }) { pruneExpired() }
        storage.withLock { state in
            state.sequence &+= 1
            state.entries[pid] = Entry(startTime: start, value: value, sequence: state.sequence)
            while state.entries.count > capacity, let oldest = state.entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                state.entries[oldest] = nil
            }
        }
    }

    func value(for pid: pid_t) -> Value? {
        let start = startTime(pid)
        return storage.withLock { state in
            guard let start, let entry = state.entries[pid], Self.matches(entry.startTime, start) else {
                state.entries[pid] = nil
                return nil
            }
            return entry.value
        }
    }

    private func pruneExpired() {
        let entries = storage.withLock { $0.entries }
        let expired = entries.filter { pid, entry in
            guard let current = startTime(pid) else { return true }
            return !Self.matches(entry.startTime, current)
        }
        storage.withLock { state in
            for (pid, entry) in expired where state.entries[pid]?.sequence == entry.sequence {
                state.entries[pid] = nil
            }
        }
    }

    private static func matches(_ lhs: timeval, _ rhs: timeval) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_usec == rhs.tv_usec
    }

    #if DEBUG
    var countForTesting: Int { storage.withLock { $0.entries.count } }
    #endif
}
