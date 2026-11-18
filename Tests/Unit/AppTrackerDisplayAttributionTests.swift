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

    func testTopologyChangeRetainsAConfirmedCGDisplayMoveWithOldAXBounds() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        tracker.updateDisplayTopology(.init(displays: tableAB.displays + [
            .init(uuid: "C", cgFrame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)

        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B-Reidentified", cgFrame: tableAB.displays[1].cgFrame)
        ], primaryUUID: "A"))
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B-Reidentified")
    }

    func testStaleAXReadRetainsAConfirmedCGDisplayMoveForTheSameWindow() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let oldAX = makeSnapshot(bounds: frameOnA, isMinimized: false)
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [oldAX], readOutcome: .success(count: 1))
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: moved, now: Date(),
            eligible: [oldAX], readOutcome: .success(count: 1))
        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B-Reidentified", cgFrame: tableAB.displays[1].cgFrame)
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B-Reidentified")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    func testCGMovementWithinTheConfirmedDisplayUpdatesBoundsUsedByLaterTopology() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        let later = cgSnapshot(bounds: [cgWindow: CGRect(x: 1750, y: 100, width: 200, height: 400)])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: later))
        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 600, height: 800)),
            .init(uuid: "C", cgFrame: CGRect(x: 1600, y: 0, width: 400, height: 800))
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "C")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    func testSameDisplayAXLocationDoesNotDiscardDifferentConfirmedCGBounds() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)], readOutcome: .success(count: 1))
        let confirmed = cgSnapshot(bounds: [cgWindow: CGRect(x: 1750, y: 100, width: 200, height: 400)])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: confirmed))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: confirmed))
        tracker.rebuildSnapshotForTesting()
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: confirmed, now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)], readOutcome: .success(count: 1))

        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 600, height: 800)),
            .init(uuid: "C", cgFrame: CGRect(x: 1600, y: 0, width: 400, height: 800))
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "C")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnB)
    }

    func testChangedAXLocationCanAdvanceBeyondConfirmedCGDisplayWhenCGIsUnavailable() {
        let table = WindowDisplayAttribution.Table(displays: tableAB.displays + [
            .init(uuid: "C", cgFrame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
        ], primaryUUID: "A")
        let tracker = makeTracker(tableProvider: { table })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let oldAX = makeSnapshot(bounds: frameOnA, isMinimized: false)
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [oldAX], readOutcome: .success(count: 1))
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))

        XCTAssertFalse(tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: .failed, now: Date(),
            eligible: [oldAX], readOutcome: .success(count: 1)))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        let newAX = makeSnapshot(bounds: CGRect(x: 2200, y: 100, width: 500, height: 400), isMinimized: false)
        XCTAssertTrue(tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: .failed, now: Date(),
            eligible: [newAX], readOutcome: .success(count: 1)))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "C")
    }

    func testNearMatchingAXFrameOnAdjacentDisplayDoesNotOverrideConfirmedCGMove() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let oldBounds = CGRect(x: 742, y: 100, width: 500, height: 400)
        let newBounds = oldBounds.offsetBy(dx: 16, dy: 0)
        let oldAX = makeSnapshot(bounds: oldBounds, isMinimized: false)
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [oldAX], readOutcome: .success(count: 1))
        let moved = cgSnapshot(bounds: [cgWindow: newBounds])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        XCTAssertFalse(tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: moved, now: Date(),
            eligible: [oldAX], readOutcome: .success(count: 1)))
        tracker.rebuildSnapshotForTesting()

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, oldBounds)
    }

    func testDisplayUUIDRetryReattributesExistingInventoryWithoutAnotherSystemNotification() {
        let incomplete = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A"],
            attributionTable: .init(displays: [tableAB.displays[0]], primaryUUID: "A"))
        let complete = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"],
            attributionTable: tableAB)
        let store = DisplayTopologyStore(initialSnapshot: incomplete)
        let tracker = makeTracker(tableProvider: { store.table })
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: nil))
        tracker.rebuildSnapshotForTesting()
        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        var snapshot = incomplete
        var retryCallbacks: [() -> Void] = []
        let orchestrator = TaskbarScreenOrchestrator(runtime: AppRuntime(tracker: tracker),
            stripOrderStore: StripOrderStore(), displayTopologyStore: store,
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, pollInterval: 0),
            overlaySpaceHost: nil, topologySnapshotProvider: { snapshot }, startCoordinator: { _ in true },
            topologyRetryScheduler: { _, action in
                retryCallbacks.append(action)
                return DispatchWorkItem(block: action)
            })
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        XCTAssertNil(tracker.snapshot.windows[windowID]?.displayUUID)

        snapshot = complete
        XCTAssertEqual(retryCallbacks.count, 2)
        retryCallbacks.first?()

        XCTAssertEqual(orchestrator.units.map(\.key), ["A", "B"])
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B")
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

    func testClosingLastWindowLeavesNoCardAndRetainsProcessObservation() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "B"))
        tracker.rebuildSnapshotForTesting()

        let empty = AppTrackerCGWindowSnapshot(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: empty, now: Date(), eligible: [], readOutcome: .success(count: 0)
        ))
        tracker.rebuildSnapshotForTesting()
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        XCTAssertTrue(tracker.snapshot.orderedWindowIDs.isEmpty)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid))


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
            element: AXUIElementCreateApplication(pid),
            isMinimizedRead: isMinimized
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
