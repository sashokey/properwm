import CoreGraphics
import XCTest

/// 跳读门控判定矩阵：每个强制全读条件单独翻转一次，外加全静跳过。
final class PeriodicReconcileSkipDecisionTests: XCTestCase {
    /// 全部条件满足、允许跳过的基线输入。
    private func quietInput() -> PeriodicReconcileSkipDecision.Input {
        PeriodicReconcileSkipDecision.Input(
            captureFailed: false,
            currentCGIDs: [77, 78],
            lastObservedCGIDs: [77, 78],
            dirtySinceLastRead: false,
            hasAbsenceClock: false,
            hasPhantomCandidate: false,
            lastReadWasUnread: false,
            lastRoundChanged: false,
            observerActive: true,
            allSeatsSubscribed: true,
            uptimeSinceLastFullRead: 5
        )
    }

    func testAllQuietSkips() {
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(quietInput()), .skip)
    }

    /// A seated window hidden without any AX notification keeps the CG id set and the dirty flag;
    /// only its on-screen change can reopen the gate.
    func testSeatOnScreenChangeForcesFullRead() {
        var input = quietInput()
        input.seatOnScreenChanged = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.seatOnScreenChanged))
    }

    func testCaptureFailureForcesFullRead() {
        var input = quietInput()
        input.captureFailed = true
        // CG 失败时即便集合「看起来」一致也必须全读——失败与空集不可区分（Docs/26 硬约束）。
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.captureFailed))
    }

    func testNeverReadForcesFullRead() {
        var input = quietInput()
        input.lastObservedCGIDs = nil
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.neverRead))
    }

    func testRefreshDueAtBoundaryForcesFullRead() {
        var input = quietInput()
        input.uptimeSinceLastFullRead = input.maxSkipInterval   // 边界取「到点即读」
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.refreshDue))
        input.uptimeSinceLastFullRead = input.maxSkipInterval - 0.001
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .skip)
    }

    func testInactiveObserverForcesFullRead() {
        var input = quietInput()
        input.observerActive = false
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.observerInactive))
    }

    func testIncompleteSubscriptionForcesFullRead() {
        var input = quietInput()
        input.allSeatsSubscribed = false
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.subscriptionIncomplete))
    }

    func testUnreadLastRoundForcesFullRead() {
        var input = quietInput()
        input.lastReadWasUnread = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.lastReadUnread))
    }

    func testDirtyEventsForceFullRead() {
        var input = quietInput()
        input.dirtySinceLastRead = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.dirtyEvents))
    }

    func testCGSetChangeForcesFullRead() {
        var input = quietInput()
        input.currentCGIDs = [77]
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.cgSetChanged))
        // 变多与变少同样触发。
        input.currentCGIDs = [77, 78, 79]
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.cgSetChanged))
    }

    func testAbsenceClockForcesFullRead() {
        var input = quietInput()
        input.hasAbsenceClock = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.absenceClockRunning))
    }

    func testPhantomCandidateForcesFullRead() {
        var input = quietInput()
        input.hasPhantomCandidate = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.phantomCandidate))
    }

    func testUnstableLastRoundForcesFullRead() {
        var input = quietInput()
        input.lastRoundChanged = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.lastRoundChanged))
    }
}
