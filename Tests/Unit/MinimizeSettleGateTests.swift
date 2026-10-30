import XCTest
@testable import macos_dock_cc_v2

final class MinimizeSettleGateTests: XCTestCase {
    /// 锚点取参考纪元 0:`addingTimeInterval(x)` 与 `timeIntervalSince(anchor)` 都精确等于 x,
    /// 边界等值用例才不会被 Double 舍入(1000 + 0.65 ≠ 精确 0.65)打成 flaky。
    private let anchor = Date(timeIntervalSinceReferenceDate: 0)

    private func verdict(
        kind: PlatformActionRequest.ActionKind = .activateWindow,
        hasAnchor: Bool = true,
        confirmed: Bool,
        elapsed: TimeInterval
    ) -> MinimizeSettleGate.Verdict {
        MinimizeSettleGate.verdict(
            requestKind: kind,
            minimizeDispatchedAt: hasAnchor ? anchor : nil,
            snapshotConfirmsMinimized: confirmed,
            now: anchor.addingTimeInterval(elapsed)
        )
    }

    /// 非 activate 的动作一律放行,即使锚还活着。
    func testNonActivateKindsAlwaysDispatch() {
        let kinds: [PlatformActionRequest.ActionKind] = [.minimizeWindow, .hideApp, .closeWindow, .quitApp, .newWindow]
        for kind in kinds {
            XCTAssertEqual(verdict(kind: kind, confirmed: false, elapsed: 0.1), .dispatchNow)
        }
    }

    /// 没有 minimize 锚 → 不设防。
    func testNoAnchorDispatches() {
        XCTAssertEqual(verdict(hasAnchor: false, confirmed: false, elapsed: 0.1), .dispatchNow)
    }

    /// 【承重,v2 语义反转】快照确认 `.minimized` 即刻放行,不再有时间地板。
    /// v1 曾在这里锁「确认也要等 0.65s」,被 owner 实测双重否决(手感 + 访达 887ms 漏兄弟):
    /// 等待不是安全来源——动画期危险分支已由执行层先验封死(强制 knownMinimized 走 07-05 v3
    /// 实测序、跳过 earlyFocus、封死 app 兜底),确认本身只承担与并发 minimize 的写顺序证明。
    func testConfirmedDispatchesImmediately() {
        for elapsed in [0.05, 0.2, 0.5, 0.99] {
            XCTAssertEqual(verdict(confirmed: true, elapsed: elapsed), .dispatchNow, "elapsed=\(elapsed)")
        }
    }

    /// 未确认 → hold 到硬上限(唯一 deadline 档)。
    func testUnconfirmedHoldsToMaxHold() {
        for elapsed in [0.1, 0.5, 0.9] {
            XCTAssertEqual(
                verdict(confirmed: false, elapsed: elapsed),
                .hold(until: anchor.addingTimeInterval(MinimizeSettleGate.maxHold)),
                "elapsed=\(elapsed)"
            )
        }
    }

    /// 【承重】过硬上限即使未确认也放行:点击不可被无限扣留(执行层仍带先验兜底)。
    func testPastMaxHoldDispatchesEvenUnconfirmed() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: 1.1), .dispatchNow)
    }

    /// 确认 + 已过硬上限 → 照样放行(边界完备性)。
    func testConfirmedPastMaxHoldStillDispatches() {
        XCTAssertEqual(verdict(confirmed: true, elapsed: 1.2), .dispatchNow)
    }

    /// deadline 单调:时间推进中重跑判定,deadline 不回退;一旦 dispatchNow 不再回到 hold。
    func testDeadlineMonotonicAcrossReevaluation() {
        var lastDeadline = Date.distantPast
        var dispatched = false
        for elapsed in stride(from: 0.05, through: 1.3, by: 0.05) {
            switch verdict(confirmed: false, elapsed: elapsed) {
            case .hold(let until):
                XCTAssertFalse(dispatched, "dispatchNow 之后不得回到 hold(elapsed=\(elapsed))")
                XCTAssertGreaterThanOrEqual(until, lastDeadline)
                lastDeadline = until
            case .dispatchNow:
                dispatched = true
            }
        }
        XCTAssertTrue(dispatched)
    }

    /// 时钟异常(锚在未来)→ 保守放行,回旧行为。
    func testNegativeElapsedDispatches() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: -0.5), .dispatchNow)
    }

    /// 边界等值:elapsed == maxHold 未确认 → 放行。
    func testBoundaryEquality() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: MinimizeSettleGate.maxHold), .dispatchNow)
    }

    /// 先验窗口:锚在 [0, priorWindow) 内 → true;到边界、无锚、时钟异常 → false。
    func testDispatchPrior() {
        func prior(_ elapsed: TimeInterval, hasAnchor: Bool = true) -> Bool {
            MinimizeSettleGate.dispatchPrior(
                minimizeDispatchedAt: hasAnchor ? anchor : nil,
                now: anchor.addingTimeInterval(elapsed)
            )
        }
        XCTAssertTrue(prior(0))
        XCTAssertTrue(prior(0.1))
        XCTAssertTrue(prior(1.5))
        XCTAssertTrue(prior(1.99))
        XCTAssertFalse(prior(MinimizeSettleGate.priorWindow))
        XCTAssertFalse(prior(2.5))
        XCTAssertFalse(prior(-0.5))
        XCTAssertFalse(prior(0.1, hasAnchor: false))
    }
}
