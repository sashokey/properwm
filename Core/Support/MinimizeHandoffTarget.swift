import CoreGraphics
import Foundation

/// 最小化前台窗口前，决定把前台交给谁（2026-08-23）。
///
/// 规则（owner 2026-08-02 定、2026-08-23 落地）：**压在目标下面的是谁就轮到谁，同应用的也算。**
/// 按 CG 在屏 z 序从目标之后往下扫，第一个**在任务条快照里**的窗口就是答案：
/// - 同 pid → `.siblingTakesOver`：什么都不做，AppKit 对前台 App 的原生提拔正好就是它；
/// - 不同 pid → `.switchTo`：最小化前先把前台交给这个 App，B 不再是前台 App，AppKit 就不会提拔 B2。
///
/// 只认快照成员，**不读 CG 标题**：`kCGWindowName` 需要屏幕录制权限，产品永不申请——原实现靠它做
/// 「无标题隐形窗口不能当交接目标」的守卫，在装机版上每个候选都被挡掉、交接从未生效（2026-08-23 实测）。
/// 快照成员资格是更强的守卫：没被任务条收编的窗口（飞书贴顶隐形条之类）根本不在快照里。
enum MinimizeHandoffTarget {
    struct ZOrderedWindow: Equatable {
        let pid: Int32
        let cgWindowID: CGWindowID
    }

    /// 两个「有接手者」分支都带上接手窗口的快照身份（2026-08-26）：接手者随即成为焦点，
    /// 但快照要 0.5–1s 才兑现——这段窗口期点接手者的卡会被误判「不是焦点」而规划成空
    /// activate（owner「收起窗 1 后快点窗 2 收不起来」）。身份交给乐观层写 .active 预测。
    enum Verdict: Equatable {
        case switchTo(pid: Int32, cgWindowID: CGWindowID, windowID: WindowID)
        case siblingTakesOver(windowID: WindowID)
        case none
    }

    /// - Parameters:
    ///   - zOrder: CG 在屏 layer-0 窗口，前→后，已排除自身进程。
    ///   - target: 即将被最小化的窗口记录。
    ///   - snapshot: 当前任务条快照。
    static func select(zOrder: [ZOrderedWindow], target: WindowRecord, snapshot: DockSnapshot) -> Verdict {
        var start = 0
        if let targetWID = target.cgWindowID,
           let index = zOrder.firstIndex(where: { $0.cgWindowID == targetWID }) {
            start = index + 1
        }
        var recordsByWID: [CGWindowID: WindowRecord] = [:]
        for record in snapshot.windows.values {
            guard let wid = record.cgWindowID, record.id != target.id else { continue }
            recordsByWID[wid] = record
        }
        for entry in zOrder[start...] {
            guard let record = recordsByWID[entry.cgWindowID] else { continue }
            guard record.status != .minimized, record.status != .hidden else { continue }
            if record.pid == target.pid {
                return .siblingTakesOver(windowID: record.id)
            }
            return .switchTo(pid: entry.pid, cgWindowID: entry.cgWindowID, windowID: record.id)
        }
        return .none
    }
}
