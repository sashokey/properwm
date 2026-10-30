import ApplicationServices
import CoreGraphics
import XCTest

/// 多屏 ④ 的清单侧：座位的粗粒度归属键（`WindowEntry.displayUUID`）什么时候变、什么时候发布。
/// 锁住三件事：跨屏移动会发布（同屏移动不发布）；最小化 / 隐藏座位冻结在最后可见的屏；
/// 被跳读门控跳过的 pid 也能靠 5s tick 的 CG bounds 遍历换屏。
@MainActor
final class AppTrackerDisplayAttributionTests: XCTestCase {
    private let pid: pid_t = 5151
    private let cgWindow: CGWindowID = 91

    private let frameOnA = CGRect(x: 100, y: 100, width: 500, height: 400)
    private let frameOnAMoved = CGRect(x: 300, y: 150, width: 500, height: 400)
    private let frameOnB = CGRect(x: 1200, y: 100, width: 500, height: 400)

    private let tableAB = WindowDisplayAttribution.Table(
        displays: [
            .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ],
        primaryUUID: "A"
    )

    func testMovingAcrossDisplaysChangesTheSignatureAndPublishes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "A")

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )

        XCTAssertTrue(changed, "跨屏移动必须算作座位变化，否则清单永远不发布新位置")
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")
    }

    func testMovingWithinOneDisplayIsNotAChange() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        let before = tracker.snapshot

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnAMoved, isMinimized: false)],
            readOutcome: .success(count: 1)
        )

        XCTAssertFalse(changed, "同屏内移动不能触发重建（指纹只含粗粒度键，不含坐标）")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertEqual(tracker.snapshot, before)
    }

    func testMinimizedSeatKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isMinimized: true))

        // AX 路：最小化窗口在别的屏读到帧，键不动。
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // CG 路：tick 的 bounds 遍历同样跳过最小化座位。
        let cgChanged = tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        )
        XCTAssertFalse(cgChanged)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testHiddenAppKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isHidden: true))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testPeriodicCGPassMovesVisibleSeatsWithoutAnAXRead() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnAMoved])
        ))
        // The first tick that sees the new display only proposes it; the second agreeing tick applies it.
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        // 只改键，不碰 AX 帧（`frameKey` / `seatsAtFrame` 靠它）。
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    /// The minimize animation drives the CG bounds across to the system Dock's display before the AX
    /// `min=true` read lands. A tick that samples it mid-flight must not move the seat — the minimize
    /// would then freeze it on the wrong display.
    func testATickDuringTheMinimizeAnimationDoesNotMoveTheSeat() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let midAnimation = CGRect(x: 1400, y: 500, width: 120, height: 90)

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: midAnimation])
        ))
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // Restored and sampled mid-flight again: the earlier proposal is gone, so this is a first sighting.
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])
        ))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: midAnimation])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testUnknownCGBoundsLeaveTheKeyAlone() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot()))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: CGRect(x: 9000, y: 9000, width: 10, height: 10)])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testScreenParametersChangeReattributesFromStoredBounds() {
        let box = TableBox(tableAB)
        let tracker = makeTracker(tableProvider: { box.table })
        // 座位存的 AX 帧在 B 区域，但装进去时键还写着 A（模拟屏表刚换）。
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        // 屏表换成「B 区域现在叫 C」。
        box.table = WindowDisplayAttribution.Table(
            displays: [
                .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                .init(uuid: "C", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
            ],
            primaryUUID: "A"
        )
        tracker.screenParametersChangedForTesting()

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "C")
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "C")
    }

    func testNewSeatTakesItsDisplayFromTheAXFrame() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [:],
            windowOrder: [],
            isHidden: false
        ))
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
    }

    /// 跨屏拖窗的乐观更新：键当场改并发布；冻结期内 AX / CG 读到的旧位置不把它弹回去，回滚不冻结。
    func testNoteWindowMovedPublishesAndHoldsAgainstStaleReads() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")

        // 冻结期内：AX 读到的帧还在 A → 不动；CG 遍历同样不动。
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])))

        // 冻结期过后（读的 now 在 hold 之后）：真值校正回 A。
        let later = Date().addingTimeInterval(AppTracker.displayMoveHold + 1)
        let corrected = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertTrue(corrected)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // 回滚（hold: .none）立刻生效且不冻结。
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "A", hold: .none))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])))
        XCTAssertFalse(tracker.noteWindowMoved(pid: pid, cgWindowID: 999, displayUUID: "B"), "不在册的座位不认")
    }

    /// AX 拿不到句柄的离屏 / 幽灵窗口：拖到别的条上 = 改住址，键钉死到它下次在 AX 里可见——
    /// CG 里的旧坐标、屏参数重算都不作数；AX 真读到可见帧才按帧走并放开。
    func testUntilVisibleHoldSurvivesCGAndStaleReadsUntilAXShowsTheWindow() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B", hold: .untilVisible))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])))
        tracker.screenParametersChangedForTesting()
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        // 很久以后 AX 仍没读到它可见（最小化态）→ 仍钉着（最小化标志本身变了算变化，与键无关）。
        let later = Date().addingTimeInterval(3600)
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        // AX 读到可见帧在 A → 按帧走、放开钉子。
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil)
    }

    /// 跨屏搬窗冻结期内座位跟着被搬的窗口走，不被旧帧上的别的窗口「撕」走：否则旧座位继承刚写成 B 的键，
    /// 被搬的窗口另建座位 → 两张卡都在 B、冻结一过旧的又跳回 A（owner 2026-09-03，多标签访达）。
    func testMoveHoldKeepsTheSeatOnTheMovedWindowInsteadOfTearingItOut() {
        let tracker = makeTracker()
        // 夹具座位用 s9：新建座位的序号计数器从 s1 起，否则和夹具 token 撞名、断言分不出谁是谁。
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", token: "tabgrp-\(pid)-s9"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        let other: CGWindowID = 92
        let cg = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow, other], onScreenWindowIDs: [cgWindow, other],
            windowIDsByPID: [pid: [cgWindow, other]], alphaByWindowID: [:], boundsByWindowID: [:]
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cg, now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false),
                       makeSnapshot(bounds: frameOnA, isMinimized: false, cgWindowID: other)],
            readOutcome: .success(count: 2)
        )
        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowsByID[cgWindow]?.token, "tabgrp-\(pid)-s9", "座位跟着被搬的窗口")
        XCTAssertEqual(app?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertNotEqual(app?.windowsByID[other]?.token, "tabgrp-\(pid)-s9", "旧帧上的窗口自成座位")
        XCTAssertEqual(app?.windowsByID[other]?.displayUUID, "A")
    }

    /// AX 写帧失败后的裁决：窗口在屏上 → 回滚；不在屏上 → 钉死到目标屏；座位不在册 → 不动。
    func testFailedMoveRollsBackOnScreenWindowsAndPinsOffScreenOnes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindow, target: "B", previous: "A"), .rolledBack)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil)

        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [])
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindow, target: "B", previous: "A"), .pinnedToTarget)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil, .distantFuture)

        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: 999, target: "B", previous: "A"), .seatGone)
    }

    /// 「在运行但没窗口」的兜底卡落在窗口最后所在的屏；拖到别的条上（`noteNoWindowHome`）改它。
    func testFallbackCardRemembersLastWindowDisplayAndAcceptsANewHome() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "B"))
        tracker.rebuildSnapshotForTesting()

        // 窗口关掉（AX 没了、CG 也没了）→ 座位释放 → 兜底卡带着「最后在 B」。
        let empty = AppTrackerCGWindowSnapshot(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: empty, now: Date(), eligible: [], readOutcome: .success(count: 0)
        ))
        tracker.rebuildSnapshotForTesting()
        let fallbackID = WindowID(rawValue: "app-com.example.fixture")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "B")

        tracker.noteNoWindowHome(bundleID: "com.example.fixture", displayUUID: "A")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "A")
        tracker.noteNoWindowHome(bundleID: "com.other", displayUUID: "B")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "A", "别的 bundle 不受影响")
    }

    // MARK: - Fixtures

    private final class TableBox {
        var table: WindowDisplayAttribution.Table
        init(_ table: WindowDisplayAttribution.Table) { self.table = table }
    }

    private func makeTracker(
        tableProvider: (@MainActor () -> WindowDisplayAttribution.Table)? = nil
    ) -> AppTracker {
        let table = tableAB
        return AppTracker(
            reader: DisplayAttributionNoopReader(),
            processProvider: DisplayAttributionFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            displayTableProvider: tableProvider ?? { table }
        )
    }

    private func cgSnapshot(bounds: [CGWindowID: CGRect] = [:]) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow],
            onScreenWindowIDs: [cgWindow],
            windowIDsByPID: [pid: [cgWindow]],
            alphaByWindowID: [:],
            boundsByWindowID: bounds
        )
    }

    private func makeApp(
        bounds: CGRect? = nil,
        displayUUID: String?,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        token: String? = nil
    ) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindow,
            token: token ?? "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: bounds ?? frameOnA,
            isMinimized: isMinimized,
            isFocused: false,
            everSeenVisible: true,
            displayUUID: displayUUID
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindow: seat],
            windowOrder: [cgWindow],
            isHidden: isHidden
        )
    }

    private func makeSnapshot(bounds: CGRect, isMinimized: Bool, cgWindowID: CGWindowID? = nil) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID ?? cgWindow,
            titleRead: .value("Window"),
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: isMinimized,
            isFocusedWindow: false,
            element: AXUIElementCreateApplication(pid)
        )
    }
}

private struct DisplayAttributionNoopReader: AppTrackerWindowReading {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .success([]) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { .success([]) }
}

private struct DisplayAttributionFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}
