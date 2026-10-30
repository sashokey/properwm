import Foundation
import XCTest

final class DockSnapshotEqualityTests: XCTestCase {
    func testEquivalentSnapshotsCompareEqual() {
        let id = WindowID(rawValue: "cgw-1")
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 42,
            bundleIdentifier: "com.example.app",
            title: "Window",
            bounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            status: .inactive,
            cgWindowID: 10,
            isOnDesktop: true,
            groupID: "seat-1"
        )
        let lhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
        let rhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])

        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, .empty)
    }
}

/// 反馈计时器按需运行的真值表。
///
/// 背景：这个计时器原先是 `start()` 里无条件起的 0.5s 循环，空闲期每秒两次把反馈态
/// 写回 `@Published`，整条任务条跟着重算——而绝大多数时候那个字典是空的。改成按需
/// 运行之后，「什么时候该转」就成了承重规则，锁在这里。
final class FeedbackTickPolicyTests: XCTestCase {

    // MARK: - 四格真值表（runtime 在跑）

    func testIdleDoesNotTick() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: false,
                hasOptimisticStates: false
            )
        )
    }

    func testFeedbackOnlyTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: true,
                hasOptimisticStates: false
            )
        )
    }

    /// 乐观态尾段：反馈条目已经清空（1.5s 结果展示到期），但乐观 overlay 还等着
    /// 兑现或 4s 超时回弹——此时仍必须继续转，否则那张 chip 的预测态永远不回弹。
    func testOptimisticOnlyTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: false,
                hasOptimisticStates: true
            )
        )
    }

    func testBothPresentTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: true,
                hasOptimisticStates: true
            )
        )
    }

    // MARK: - 承重规则：runtime 停了就永远不转

    /// `AppRuntime.trigger()` 的 detached 执行回调会在 `stop()` 之后才回到主线程写
    /// 反馈态。没有这条门，那次回调就会把已经停掉的计时器复活——runtime 停了、
    /// 计时器还在每 0.5s 空转，而且再没有人来关它。
    func testStoppedRuntimeNeverTicksEvenWithPendingWork() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: true,
                hasOptimisticStates: true
            )
        )
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: true,
                hasOptimisticStates: false
            )
        )
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: false,
                hasOptimisticStates: true
            )
        )
    }

    func testStoppedRuntimeIdleDoesNotTick() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: false,
                hasOptimisticStates: false
            )
        )
    }
}

/// 反馈态自身的生命周期——计时器按需运行之后，「条目会不会自己走到空」直接决定
/// 计时器会不会停。这几条锁住 retention 语义没被改动。
final class IntentFeedbackStateRetentionTests: XCTestCase {

    private let windowID = "cgw-1"

    private func snapshot(status: WindowStatus) -> DockSnapshot {
        let id = WindowID(rawValue: windowID)
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 1234,
            bundleIdentifier: "com.example.app",
            title: "窗口",
            bounds: nil,
            status: status,
            isOnDesktop: true,
            groupID: windowID
        )
        return DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
    }

    /// pending 超过 4s 未兑现 → 转 failure（而不是留在 pending 里永远转下去）。
    func testPendingBecomesFailureAfterRetention() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .inactive), now: start.addingTimeInterval(4.5))

        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)
    }

    /// **即时失败、随后快照兑现**：`AccessibilitySource.minimize` 按下最小化按钮后立刻回读
    /// `kAXMinimizedAttribute`，而最小化是动画操作——这一读经常还没跟上，于是执行器报
    /// failure。真实快照随后显示窗口确实最小化了，必须能把它纠正成 success。
    ///
    /// 这条是回归护栏：为了让按需计时器能停下来，曾经把「所有终态一律跳过对账」当成修法，
    /// 那样写就把这条升级路径一起删掉了。
    func testFailureIsUpgradedToSuccessWhenSnapshotLaterConfirms() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        // 执行器即时回读失败 → failure
        state.markFailed(windowID: windowID, action: .minimize, at: start.addingTimeInterval(0.05))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)

        // 稍后真实快照显示窗口已最小化 → 纠正为 success
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.4))
        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.phase,
            .success,
            "failure 必须能被后续真实快照纠正——AX 动作可能已生效而即时回读没跟上"
        )
    }

    /// 同相位不刷新时间戳：窗口保持在目标状态时，每轮对账都会再次判定成功，但不能把
    /// `updatedAt` 一轮轮盖成 now，否则条目永不过期、按需计时器永远停不下来。
    func testSuccessIsNotRestampedWhileWindowStaysInTargetState() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.2))
        let firstSuccessAt = state.entriesByWindowID[windowID]?.updatedAt
        XCTAssertNotNil(firstSuccessAt)

        // 又过了一轮，窗口仍然最小化
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.7))

        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.updatedAt,
            firstSuccessAt,
            "同相位重复对账不能刷新 updatedAt，否则 1.5s retention 永远走不到"
        )
    }

    /// terminal 态（success / failure）展示 1.5s 后条目被清空 —— 这是计时器能停下来的前提。
    func testTerminalEntryIsDroppedAfterRetentionSoTheTimerCanStop() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        // 兑现：窗口真的最小化了 → success
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.5))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .success)

        // 1.5s 结果展示到期 → 条目消失，字典变空
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(2.2))
        XCTAssertTrue(
            state.entriesByWindowID.isEmpty,
            "terminal 条目没被清掉的话，按需计时器就永远停不下来"
        )
    }
}
