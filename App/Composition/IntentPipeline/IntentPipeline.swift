import Foundation
import os

@MainActor
final class IntentPipeline {
    private let actionPlanning: LifecycleActionPlanner
    private(set) var feedbackState = IntentFeedbackState()
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "intent-pipeline")

    init(actionPlanning: LifecycleActionPlanner) {
        self.actionPlanning = actionPlanning
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        optimisticStates: [String: OptimisticWindowState] = [:]
    ) -> PlatformActionRequest {
        actionPlanning.plan(intent: intent, snapshot: snapshot, optimisticStates: optimisticStates)
    }

    func canBegin(intent: UserIntent) -> Bool {
        feedbackState.canBegin(windowID: intent.windowID.rawValue)
    }

    func registerPending(intent: UserIntent, request: PlatformActionRequest) {
        feedbackState.begin(
            windowID: intent.windowID.rawValue,
            action: feedbackAction(for: request, fallback: intent.action),
            at: Date()
        )
    }

    func registerExecutionResult(intent: UserIntent, request: PlatformActionRequest, success: Bool) {
        let action = feedbackAction(for: request, fallback: intent.action)
        if success {
            feedbackState.markSucceededImmediatelyIfNeeded(
                windowID: intent.windowID.rawValue,
                action: action,
                at: Date()
            )
        } else {
            feedbackState.markFailed(windowID: intent.windowID.rawValue, action: action, at: Date())
        }
    }

    func reconcile(with snapshot: DockSnapshot) {
        let before = feedbackState.entriesByWindowID
        feedbackState.reconcile(snapshot: snapshot, now: Date())
        for (windowID, entry) in feedbackState.entriesByWindowID {
            if let old = before[windowID], old.phase == .pending, entry.phase != .pending {
                logger.info("[B-pending-cleared] t=\(CFAbsoluteTimeGetCurrent(), privacy: .public) windowID=\(windowID, privacy: .public) action=\(entry.action.rawValue, privacy: .public) → \(entry.phase.rawValue, privacy: .public)")
            }
        }
    }

    private func feedbackAction(
        for request: PlatformActionRequest,
        fallback: UserIntentAction
    ) -> UserIntentAction {
        switch request.kind {
        case .activateWindow:
            return .activate
        case .minimizeWindow:
            return .minimize
        case .hideApp:
            return .hide
        case .closeWindow:
            return .close
        case .quitApp:
            return .quit
        case .newWindow:
            return .newWindow
        }
    }
}

/// 反馈计时器该不该转的纯判定。
///
/// 为什么抽出来：`AppRuntime` 自己构造 `AppTracker` / `PermissionService`（都要碰 AX / CG），
/// 单测里起不来，所以这张真值表只能锁在纯类型上。规则很短，但有一条是承重的——
/// **runtime 已停时永远 false**：`AppRuntime.trigger()` 的 detached 执行回调会在 `stop()`
/// 之后才回到主线程写反馈态，没有这一条就会把已经停掉的计时器复活，于是 runtime 停了、
/// 计时器还在每 0.5s 空转。
enum FeedbackTickPolicy {
    /// - Parameters:
    ///   - isRunning: runtime 是否在跑（`AppRuntime` 用 `snapshotSubscription != nil` 喂）。
    ///   - hasFeedbackEntries: `IntentFeedbackState` 还有没有待对账的条目。
    ///   - hasOptimisticStates: 乐观态 overlay 还有没有待兑现 / 待超时回弹的条目。
    static func shouldTick(
        isRunning: Bool,
        hasFeedbackEntries: Bool,
        hasOptimisticStates: Bool
    ) -> Bool {
        guard isRunning else { return false }
        return hasFeedbackEntries || hasOptimisticStates
    }
}

struct IntentFeedbackState {
    private(set) var entriesByWindowID: [String: Entry] = [:]

    func canBegin(windowID: String) -> Bool {
        guard let entry = entriesByWindowID[windowID] else { return true }
        return entry.phase != .pending
    }

    mutating func begin(windowID: String, action: UserIntentAction, at timestamp: Date) {
        let entry = Entry(
            windowID: windowID,
            action: action,
            phase: .pending,
            updatedAt: timestamp
        )
        entriesByWindowID[windowID] = entry
    }

    mutating func markSucceededImmediatelyIfNeeded(
        windowID: String,
        action: UserIntentAction,
        at timestamp: Date
    ) {
        // newWindow opens a *new* window (a different windowID), so it can never be
        // confirmed by reconciling this chip's snapshot status. Treat a successful
        // executor return as immediate success, same as activate.
        if action == .activate || action == .newWindow {
            update(windowID: windowID, phase: .success, at: timestamp)
        }
    }

    mutating func markFailed(windowID: String, action: UserIntentAction, at timestamp: Date) {
        update(windowID: windowID, phase: .failure, at: timestamp)
    }

    mutating func reconcile(snapshot: DockSnapshot, now: Date) {
        for (windowID, entry) in entriesByWindowID {
            if entry.phase == .pending,
               now.timeIntervalSince(entry.updatedAt) > entry.phase.retention {
                update(windowID: windowID, phase: .failure, at: now)
                continue
            }

            guard let typedWindowID = snapshot.orderedWindowIDs.first(where: { $0.rawValue == windowID }) ?? snapshot.windows.keys.first(where: { $0.rawValue == windowID }) else {
                if entry.action == .close {
                    update(windowID: windowID, phase: .success, at: now)
                }
                continue
            }

            guard let record = snapshot.windows[typedWindowID] else { continue }

            switch entry.action {
            case .toggle:
                break
            case .activate:
                if record.status == .active {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .minimize:
                if record.status == .minimized || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .hide:
                if record.status == .hidden || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .close:
                if record.status == .closedPending {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .quit:
                if record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .newWindow:
                // Success was marked immediately on executor return; nothing to
                // reconcile here (the new window is a separate windowID).
                break
            }
        }

        entriesByWindowID = entriesByWindowID.filter { _, entry in
            now.timeIntervalSince(entry.updatedAt) <= entry.phase.retention
        }
    }

    /// 只在**相位真的变了**时才写。
    ///
    /// 为什么要这道门：`reconcile` 每轮都会对已兑现的条目重跑一次判定，窗口只要保持在目标
    /// 状态（最小化 / 隐藏 / 激活），原先就会把 `updatedAt` 一轮一轮盖成 now——那条 success
    /// 永远走不到 1.5s 过期，条目字典永不清空。旧的常驻计时器把这一点掩盖了（反正它一直在
    /// 转）；改成按需运行后，这会让计时器永远停不下来，整个优化不生效。
    ///
    /// 但只能冻结「同相位重复刷新」，**不能**跳过所有终态：AX 动作可能已经生效而即时回读仍
    /// 返回 false（`AccessibilitySource.minimize` 按下按钮后立刻读 `kAXMinimizedAttribute`，
    /// 最小化是动画操作，这一读经常还没跟上），于是先被记成 failure，要靠后续真实快照纠正成
    /// success。`failure → success` 这条升级路径必须留着。
    private mutating func update(windowID: String, phase: FeedbackPhase, at timestamp: Date) {
        guard var entry = entriesByWindowID[windowID], entry.phase != phase else { return }
        entry.phase = phase
        entry.updatedAt = timestamp
        entriesByWindowID[windowID] = entry
    }

    struct Entry: Hashable {
        let windowID: String
        let action: UserIntentAction
        var phase: FeedbackPhase
        var updatedAt: Date
    }

    enum FeedbackPhase: String, Hashable {
        case pending
        case success
        case failure

        var retention: TimeInterval {
            switch self {
            case .pending:
                return 4.0
            case .success, .failure:
                return 1.5
            }
        }
    }
}
