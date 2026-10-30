import Foundation
import CoreGraphics

struct WindowRecord: Hashable, Sendable {
    let id: WindowID
    let appID: AppID
    let pid: Int32
    let bundleIdentifier: String?
    var title: String
    var bounds: CGRect?
    var status: WindowStatus
    var cgWindowID: CGWindowID?
    var isOnDesktop: Bool
    /// 稳定分组身份（标签组根治）。同一物理窗口的所有原生标签座位共享同一个 token，一旦分配就
    /// **不随当前激活标签的 CGWindowID 变化**；普通单窗口是自成一组的 token。任务条据此合并、
    /// 并以它作为卡片的稳定 id（切标签 / 后台标签来去都不换身份证 → 卡片不跳不裂）。
    /// 默认空串 = 退化为按 `id` 各自独立（兼容未赋值路径）。
    var groupID: String
    /// 窗口在哪块屏（display UUID，粗粒度归属键；多屏 ④ 按它过滤窗口卡）。nil = 清单读不到位置
    /// （兜底卡、还没读到帧）——落主屏由投影层决定，这里不猜。最小化 / 隐藏期间冻结在最后可见的屏。
    var displayUUID: String?

    init(
        id: WindowID,
        appID: AppID,
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        bounds: CGRect?,
        status: WindowStatus,
        cgWindowID: CGWindowID? = nil,
        isOnDesktop: Bool = false,
        groupID: String = "",
        displayUUID: String? = nil
    ) {
        self.id = id
        self.appID = appID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.bounds = bounds
        self.status = status
        self.cgWindowID = cgWindowID
        self.isOnDesktop = isOnDesktop
        self.groupID = groupID.isEmpty ? id.rawValue : groupID
        self.displayUUID = displayUUID
    }
}

enum WindowStatus: String, Hashable, Codable, Sendable {
    case active
    case inactive
    case minimized
    case hidden
    case closedPending
    case disappeared
}

/// 乐观状态 overlay（交互打磨 2026-06-13）：点击发出显隐类动作（activate / minimize /
/// hide）的瞬间，先本地假定窗口已变成目标状态，UI 与下一次 toggle 规划都优先读它，
/// 不等快照 round-trip —— 这就是「可打断 / 连点衔接」的根。真实快照兑现预测或超时
/// 后清除（静默回弹）。close / quit 不写乐观态（窗口要消失，失败回弹会闪）。
///
/// 只预测 status，不预测前台轴（2026-07-05）：前台轴有即时准确的系统读数（新建
/// NSRunningApplication 实例的 isActive，SkyLight 切换后立即翻面），预测它只会出错——
/// 曾有残留满 4s 的 isAppFrontmost=true 把「别的 App 在前时点卡片」误规划成 minimize。
struct OptimisticWindowState: Hashable, Sendable {
    let status: WindowStatus
    let createdAt: Date
    /// 该 .active 预测描述的是「焦点正经由系统过渡抵达本窗」：还原动画（点最小化窗口
    /// 还原），或收起交接（收起焦点窗后系统提拔的接手者）。过渡期间快照可能短暂把
    /// 兄弟证实 .active（残影），顶替清除对这类预测有 1.5s 宽限
    ///（见 `supersededByActiveSibling`）。省略即 false（用户点击可见窗口的普通激活）。
    let focusHandoffGrace: Bool
    /// 该预测由系统推断产生（收起交接的接手者预测），而非用户点击。系统预测的证据强度
    /// 低于用户动作：被快照证伪（窗口实为 minimized/hidden）时立即清除，见
    /// `systemPredictionFalsified`。省略即 false（用户动作出身，语义正确）。
    let systemPredicted: Bool

    init(status: WindowStatus, createdAt: Date, focusHandoffGrace: Bool = false, systemPredicted: Bool = false) {
        self.status = status
        self.createdAt = createdAt
        self.focusHandoffGrace = focusHandoffGrace
        self.systemPredicted = systemPredicted
    }
}

extension OptimisticWindowState {
    /// 兄弟顶替即清（2026-08-22）：预测 .active 尚未兑现、而同 App 另一窗口已被快照证实
    /// .active —— 焦点已被兄弟拿走，这份预测再挂满 4 秒只会把下一次点击误规划成 minimize。
    /// macOS 26 曾把 SkyLight make-key 静默废掉，误最小化正是靠这类残留发作；留这层防御，
    /// 未来焦点通道再静默失效时症状降级为「多余的 activate」而不是「误 minimize」。
    /// 只清 .active 预测：minimize / hidden 的兑现语义（含 disappeared）与兄弟状态无关。
    /// 过渡宽限（2026-08-26，原「还原宽限」推广到收起交接）：焦点过渡出身的 .active
    /// 预测在此窗口内不被兄弟顶替清除。访达实测：过渡期 App 已前台、焦点仍挂在可见
    /// 兄弟上，快照短暂把兄弟证实 .active，10–530ms 就把预测顶掉，之后 ~1s 内的收起
    /// 点击全被降级成空 activate（owner「点了不收」）。1.5s 上限覆盖访达 887ms 动画。
    static let handoffSupersessionGrace: TimeInterval = 1.5

    /// 系统预测证伪（2026-08-26 Release 风暴实测）：交接预测可能落在一扇实际已收起的窗上
    ///（快照滞后 + 收起动画期窗口仍在 CG 在屏表），这份错误的 .active 带着宽限存活，会把
    /// 之后的唤醒点击误规划成收起，反复无效直到 4s 超时。快照说这窗 minimized/hidden 即
    /// 与「即将成为焦点」矛盾 → 立即清除，点击回到 activate（= 还原，正合用户意图）。
    /// **只清系统预测**：用户自己「还原→再收起」的交替态（乐观 .active + 快照 .minimized）
    /// 是正常在飞状态，绝不能清。
    static func systemPredictionFalsified(state: OptimisticWindowState, actual: WindowStatus) -> Bool {
        guard state.systemPredicted, state.status == .active else { return false }
        return actual == .minimized || actual == .hidden
    }

    /// 顶替清除的完整判定（reconcile 用）。
    ///
    /// 兄弟「已证实 .active」有一条**在飞折扣**：兄弟自己持有在飞的乐观 .minimized /
    /// .hidden（用户刚收起/隐藏它）时，它快照里的 .active 是被用户动作抵触的残影，不算
    /// 焦点接手者——否则收起窗 1 在飞期间，其 active 残影会立刻顶掉刚写给接手窗 2 的预测。
    ///
    /// 宽限豁免需同时满足：预测带 `focusHandoffGrace`、未过宽限、没有任何同 pid 兄弟
    /// 自己也持有乐观 .active（有 = 用户真点了兄弟卡，焦点是真被拿走，预测照清——
    /// 保住「宁可多余 activate，绝不错误 minimize」的底线）。
    static func supersededByActiveSibling(
        windowID: String,
        state: OptimisticWindowState,
        now: Date,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot,
        handoffGraceEnabled: Bool
    ) -> Bool {
        guard state.status == .active else { return false }
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let crediblyActiveSibling = snapshot.windows.values.contains { sibling in
            guard sibling.pid == record.pid, sibling.id != record.id, sibling.status == .active else {
                return false
            }
            let inFlight = optimisticStates[sibling.id.rawValue]?.status
            return inFlight != .minimized && inFlight != .hidden
        }
        guard crediblyActiveSibling else { return false }
        guard handoffGraceEnabled,
              state.focusHandoffGrace,
              now.timeIntervalSince(state.createdAt) <= Self.handoffSupersessionGrace
        else { return true }
        let siblingActivationClicked = optimisticStates.contains { key, sibling in
            guard key != windowID, sibling.status == .active else { return false }
            guard let siblingRecord = snapshot.windows[WindowID(rawValue: key)] else { return false }
            return siblingRecord.pid == record.pid
        }
        return siblingActivationClicked
    }

    /// 兄弟激活在飞（2026-08-25）：同 App 另一窗口持有尚未被快照兑现的乐观 .active——
    /// 焦点正在交接途中，此刻本窗口的「active」读数（快照或乐观残留）都不可信：来回快点
    /// 两个可见窗口时，点后台窗曾被误收起（Release 实测，click-latency 里 6 条
    /// 「快照 inactive 却规划成 minimize」）。用于 toggle 规划的收起判定降级
    /// （见 LifecycleActionPlanner），哲学同上一条：宁可多余 activate，绝不错误 minimize。
    static func siblingActivationInFlight(
        windowID: String,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot
    ) -> Bool {
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let ownActivationCreatedAt: Date? = {
            guard let own = optimisticStates[windowID], own.status == .active else { return nil }
            return own.createdAt
        }()
        return optimisticStates.contains { key, state in
            guard key != windowID, state.status == .active else { return false }
            guard let sibling = snapshot.windows[WindowID(rawValue: key)] else { return false }
            guard sibling.pid == record.pid, sibling.status != .active else { return false }
            // 时序裁决（2026-08-26，Release 批量还原实测）：本窗自己的乐观 .active 比该
            // 兄弟的更新 → 用户最近一次激活意图落在本窗，第二击是同窗严格交替（该收起），
            // 不降级——否则批量还原后逐窗收起全被压成空激活。兄弟的更新（或本窗无乐观态、
            // 只有快照残影）→ 焦点正流向兄弟，维持 08-25 降级，误收起底线不破。
            if let own = ownActivationCreatedAt, own > state.createdAt { return false }
            return true
        }
    }
}
