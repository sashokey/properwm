import ApplicationServices
import CoreGraphics
import Synchronization
import XCTest

/// 周期对账批量后台读（schedulePeriodicBatchRead / completePeriodicBatch）的行为锁：
/// 每 pid 恰读一次并落地、在途事件读抑制批读、代际变更丢弃落地、`.unread` 不动座位状态。
@MainActor
final class AppTrackerPeriodicBatchTests: XCTestCase {
    private let pidA: pid_t = 4242
    private let pidB: pid_t = 4343
    private let cgWindowA: CGWindowID = 77
    private let cgWindowB: CGWindowID = 88

    func testPeriodicReadKeepsConfirmedMinimizeWhenKnownWindowFrameIsUnread() async throws {
        try await assertConfirmedMinimizeWithUnreadFrame(subrole: nil)
        try await assertConfirmedMinimizeWithUnreadFrame(subrole: kAXStandardWindowSubrole as String)
    }

    func testPeriodicReadKeepsConfirmedMinimizeWhenCGCaptureFails() async throws {
        try await assertConfirmedMinimizeWithUnreadFrame(subrole: nil, minimizedCG: .failed)
    }

    func testPeriodicReadKeepsConfirmedMinimizeWhenCGOmitsWindow() async throws {
        let emptyCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]
        )
        try await assertConfirmedMinimizeWithUnreadFrame(subrole: nil, minimizedCG: emptyCG)
    }

    func testPeriodicReadKeepsSeatWhenTheSameAXWindowChangesCGID() async throws {
        let siblingID: CGWindowID = 99
        let initial = makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")
        let sibling = makeSnapshot(pid: pidA, cgWindowID: siblingID, title: "Sibling",
            element: AXUIElementCreateApplication(pidB))
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([initial, sibling])])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider())
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.runPeriodicBatchForTesting(cgSnapshot: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, siblingID], onScreenWindowIDs: [cgWindowA, siblingID],
            windowIDsByPID: [pidA: [cgWindowA, siblingID]], alphaByWindowID: [:],
            parentWindowIDs: [cgWindowA: 0, siblingID: 0]
        ))
        await drainInventory(tracker)
        let before = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowOrder, [cgWindowA, siblingID])

        let moved = makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: "Moved window",
            element: AXUIElementCreateApplication(pidA), bounds: CGRect(x: 600, y: 80, width: 500, height: 400))
        XCTAssertTrue(CFEqual(initial.element, moved.element))
        reader.setResult(.success([sibling, moved]), for: pidA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB, siblingID], onScreenWindowIDs: [cgWindowB, siblingID],
            windowIDsByPID: [pidA: [cgWindowA, cgWindowB, siblingID]], alphaByWindowID: [:],
            parentWindowIDs: [cgWindowA: 0, cgWindowB: 0, siblingID: 0]
        ))
        await drainInventory(tracker)

        let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA))
        XCTAssertEqual(app.windowOrder, [cgWindowB, siblingID])
        XCTAssertNil(app.windowsByID[cgWindowA])
        XCTAssertEqual(app.windowsByID[cgWindowB]?.token, before.token)
        XCTAssertEqual(app.windowsByID[cgWindowB]?.actionTarget?.id, before.actionTarget?.id)
        XCTAssertEqual(app.windowsByID[cgWindowB]?.formerCgIDs, [])
        XCTAssertEqual(app.windowsByID[cgWindowB]?.bounds, moved.bounds)
        XCTAssertNil(AXElementCache.shared.element(pid: pidA, cgWindowID: cgWindowA))
    }

    func testPeriodicReadDoesNotTransferSeatToAnAmbiguousCGID() async throws {
        let sameElement = makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: "Previous window")
        let differentElement = makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: "Different window",
            element: AXUIElementCreateApplication(pidB))
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([sameElement, differentElement])])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider())
        defer { tracker.stop() }
        var previous = makeApp(pid: pidA, cgWindowID: cgWindowA)
        let target = WindowActionTarget(element: AXElementKey(e: sameElement.element))
        previous.windowsByID[cgWindowA]?.actionTarget = target
        tracker.installFixtureForTesting(previous)
        tracker.runPeriodicBatchForTesting(cgSnapshot: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [cgWindowB],
            windowIDsByPID: [pidA: [cgWindowA, cgWindowB]], alphaByWindowID: [:],
            parentWindowIDs: [cgWindowA: 0, cgWindowB: 0]
        ))
        await drainInventory(tracker)

        let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA))
        XCTAssertEqual(app.windowOrder, [cgWindowA, cgWindowB])
        XCTAssertEqual(app.windowsByID[cgWindowA]?.actionTarget?.id, target.id)
        XCTAssertNotEqual(app.windowsByID[cgWindowB]?.actionTarget?.id, target.id)
    }

    func testPeriodicReadPrefersKnownAXElementAmongSameCGCandidates() async throws {
        let initial = makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([initial])])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider())
        defer { tracker.stop() }
        let capture = cgSnapshot()
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.runPeriodicBatchForTesting(cgSnapshot: capture)
        await drainInventory(tracker)
        let before = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
        XCTAssertTrue(before.matchesAXElement(initial.element))

        let alias = makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Focused alias",
            element: AXUIElementCreateApplication(pidB))
        for aliasFirst in [true, false] {
            let title = aliasFirst ? "Alias first" : "Alias last"
            let updated = makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: title)
            let observations = aliasFirst ? [alias, updated] : [updated, alias]
            reader.setResult(.success(observations), for: pidA)
            tracker.runPeriodicBatchForTesting(cgSnapshot: capture)
            await drainInventory(tracker)

            let after = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
            XCTAssertEqual(after.token, before.token)
            XCTAssertEqual(after.title, title)
            XCTAssertEqual(after.actionTarget?.id, before.actionTarget?.id)
        }
    }

    private func assertConfirmedMinimizeWithUnreadFrame(
        subrole: String?, minimizedCG: AppTrackerCGWindowSnapshot? = nil
    ) async throws {
        let visible = makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([visible])])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider())
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.runPeriodicBatchForTesting(cgSnapshot: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA]], alphaByWindowID: [:], parentWindowIDs: [cgWindowA: 0]
        ))
        await drainInventory(tracker)
        let before = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
        XCTAssertTrue(before.matchesAXElement(visible.element))

        let minimized = AXWindowSnapshot(pid: pidA, cgWindowID: cgWindowA, titleRead: .unread(.cannotComplete),
            bounds: nil, role: visible.role, subrole: subrole, isMinimized: true,
            isFocusedWindow: false, element: visible.element, isMinimizedRead: true)
        let unknown = AXWindowSnapshot(pid: pidA, cgWindowID: cgWindowB, titleRead: .value("Unknown"),
            bounds: nil, role: visible.role, subrole: nil, isMinimized: true,
            isFocusedWindow: false, element: visible.element, isMinimizedRead: true)
        reader.setResult(.success([minimized, unknown]), for: pidA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: minimizedCG ?? AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [],
            windowIDsByPID: [pidA: [cgWindowA, cgWindowB]], alphaByWindowID: [:],
            parentWindowIDs: [cgWindowA: 0, cgWindowB: 0]
        ))
        await drainInventory(tracker)

        let after = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
        XCTAssertTrue(after.isMinimized)
        XCTAssertEqual(after.token, before.token)
        XCTAssertEqual(after.bounds, before.bounds)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.actionTarget?.id, before.actionTarget?.id)
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        if AXElementCache.isEnabled {
            let cached = try XCTUnwrap(AXElementCache.shared.element(pid: pidA, cgWindowID: cgWindowA))
            XCTAssertTrue(CFEqual(cached, visible.element))
        }
    }

    func testStalePeriodicCaptureCannotRetireNewOwnerAfterUnreadAX() async {
        await assertNewOwnerSurvivesStalePeriodicCapture(readable: false)
    }

    func testStalePeriodicCaptureRejectsReusedIDAndAppliesOtherAXUpdates() async {
        await assertNewOwnerSurvivesStalePeriodicCapture(readable: true)
    }

    func testStaleFailedPeriodicCaptureCannotOverrideNewerConfirmedOwnership() async {
        await assertNewOwnerSurvivesStalePeriodicCapture(readable: true, captureFailed: true)
    }

    func testOlderPeriodicCaptureCannotRetireAnOwnerUpdatedWithFailedCG() async {
        await assertNewOwnerSurvivesStalePeriodicCapture(readable: true, newerCaptureFailed: true)
    }

    func testStalePeriodicForeignOwnerCannotRemoveASeatConfirmedByNewerCapture() async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Updated A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Updated B")]
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        let oldCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [cgWindowA, cgWindowB],
            windowIDsByPID: [pidB: [cgWindowA, cgWindowB]], alphaByWindowID: [:]
        )
        tracker.runPeriodicBatchForTesting(cgSnapshot: oldCG)
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.scheduleEventReadForTesting(pid: pidB, source: .titleChanged)
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title == "Updated B" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title, "Updated B")

        reader.release()
        await drainInventory(tracker)
        let seat = tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]
        XCTAssertEqual(seat?.title, "Updated A")
        XCTAssertEqual(seat?.token, "tabgrp-4242-s1")
    }

    private func assertNewOwnerSurvivesStalePeriodicCapture(
        readable: Bool, captureFailed: Bool = false, newerCaptureFailed: Bool = false
    ) async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Updated A"),
                   makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: "Stale A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "New B")]
        ], unreadPIDs: readable ? [] : [pidA], returnsAllSnapshots: true)
        let newCG = newerCaptureFailed ? .failed : cgSnapshot()
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { newCG })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        let oldCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [cgWindowA, cgWindowB],
            windowIDsByPID: [pidA: [cgWindowA, cgWindowB]], alphaByWindowID: [:]
        )
        tracker.runPeriodicBatchForTesting(cgSnapshot: captureFailed ? .failed : oldCG)
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.scheduleEventReadForTesting(pid: pidB, source: .titleChanged)
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title == "New B" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.pid, pidB)

        reader.release()
        await drainInventory(tracker)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.pid, pidB)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidB)?.windowsByID[cgWindowB]?.title, "New B")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title,
                       readable ? "Updated A" : "Window")
    }

    func testLaterPIDEventDoesNotWaitForEarlierBlockedPeriodicRead() async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Periodic A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Event B")]
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.scheduleEventReadForTesting(pid: pidB, source: .titleChanged)
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title == "Event B" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title, "Event B")
        XCTAssertEqual(reader.reads(for: pidB), 1)

        reader.release()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        await waitUntil(timeoutNanoseconds: 100_000_000) { reader.reads(for: self.pidB) > 1 }
        XCTAssertEqual(reader.reads(for: pidB), 1)
    }

    func testQueuedPeriodicReadUsesLatestMutationGenerationAtAdmission() async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Periodic A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Latest B")]
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.minimizeForTesting(pid: pidB, cgWindowID: cgWindowB)
        reader.release()
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title == "Latest B" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title, "Latest B")
        XCTAssertEqual(reader.reads(for: pidB), 1)
    }

    func testQueuedPeriodicReadIsNotDuplicatedAcrossBatches() async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Periodic A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Periodic B")]
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil(timeoutNanoseconds: 100_000_000) { reader.reads(for: self.pidB) > 0 }
        XCTAssertEqual(reader.reads(for: pidB), 0)
        reader.release()
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title == "Periodic B" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title, "Periodic B")
        XCTAssertEqual(reader.reads(for: pidB), 1)
    }

    func testStoppingBatchDoesNotStartQueuedPIDRead() async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Periodic A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Periodic B")]
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.stop()
        reader.release()
        await waitUntil { reader.finishedBlockedRead }
        XCTAssertTrue(reader.finishedBlockedRead)
        await waitUntil(timeoutNanoseconds: 100_000_000) { reader.reads(for: self.pidB) > 0 }
        XCTAssertEqual(reader.reads(for: pidB), 0)
        XCTAssertEqual(tracker.snapshot, .empty)
    }

    func testReplacedQueuedProcessIsNotReadByTheOldBatch() async {
        let reader = SelectivePeriodicReader(blockedPID: pidA, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Periodic A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Old B")]
        ])
        let process = BatchMutableProcessProvider()
        let tracker = AppTracker(reader: reader, processProvider: process,
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)

        tracker.terminateForTesting(pid: pidB)
        process.advanceGeneration()
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        reader.release()
        await waitUntil { reader.finishedBlockedRead }
        XCTAssertTrue(reader.finishedBlockedRead)
        await waitUntil(timeoutNanoseconds: 100_000_000) { reader.reads(for: self.pidB) > 0 }
        XCTAssertEqual(reader.reads(for: pidB), 0)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidB)?.windowsByID[cgWindowB]?.title, "Window")
    }

    func testReadyPIDPublishesAndConsumesItsNextEventWhileAnotherPIDIsBlocked() async {
        let reader = SelectivePeriodicReader(blockedPID: pidB, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Ready A"),
                   makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Follow-up A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Ready B")]
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title == "Ready A" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "Ready A")
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pidA))
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))

        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title == "Follow-up A" }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "Follow-up A")
        XCTAssertEqual(reader.reads(for: pidA), 2)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))

        reader.release()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidB) }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.title, "Ready B")
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "Follow-up A")
    }

    func testQueuedTrailingEventCompletesBeforeAnotherPeriodicPIDReturns() async {
        let reader = SelectivePeriodicReader(blockedPID: pidB, results: [
            pidA: [makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Ready A"),
                   makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Queued follow-up A")],
            pidB: [makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Ready B")]
        ], firstReadGatePID: pidA)
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { reader.releaseFirstRead(); reader.release(); tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { reader.isFirstReadBlocked }
        XCTAssertTrue(reader.isFirstReadBlocked)
        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        reader.releaseFirstRead()
        await waitUntil { reader.isBlocked }
        XCTAssertTrue(reader.isBlocked)
        await waitUntil { tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title == "Queued follow-up A" }

        XCTAssertEqual(reader.reads(for: pidA), 2)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "Queued follow-up A")
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pidA))
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))
    }

    func testBatchReadsEachTrackedPidOnceAndAppliesResult() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")]),
            pidB: .success([makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Renamed B")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider()
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))

        await waitUntil {
            !tracker.hasPendingEventReadForTesting(pid: self.pidA)
                && !tracker.hasPendingEventReadForTesting(pid: self.pidB)
        }

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Renamed A")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidB)?.windowsByID[cgWindowB]?.title, "Renamed B")
    }

    func testInFlightEventReadSuppressesPeriodicBatchForThatPid() async {
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))

        // 事件读在途 → 本轮批读必须跳过该 pid，不注册第二个 pending。
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())

        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        // 只有事件读那一次；批读没有为同 pid 排第二次。
        XCTAssertEqual(reader.readCount, 1)
    }

    func testGenerationBumpMidFlightDiscardsBatchLanding() async {
        let provider = BatchMutableProcessProvider()
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: provider
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        // 读还堵在探针里，此刻换代（pid 复用）：落地必须被身份检查拦下。
        provider.advanceGeneration()
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Window")
    }

    func testUnreadBatchRoundLeavesSeatStateUntouched() async {
        let absence = Date(timeIntervalSince1970: 10)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider()
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.minAbsentSince = absence
        app.shadowTabCgIDs = [91, 92]
        tracker.installFixtureForTesting(app)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        let after = tracker.fixtureAppForTesting(pid: pidA)
        XCTAssertEqual(after?.windowOrder, [cgWindowA])
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.title, "Window")
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.minAbsentSince, absence)
        XCTAssertEqual(after?.shadowTabCgIDs, [91, 92])
        XCTAssertEqual(reader.readCount, 1)
    }

    // MARK: - 跳读门控集成（DOCK_RECONCILE_SKIP 默认开）

    func testQuiescentPidIsSkippedOnSecondBatch() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider()
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        // 第二轮：无事件、CG 集不变、上一轮无变化 → 跳过，连 pending 都不注册。
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil(timeoutNanoseconds: 300_000_000) { reader.readCount > 1 }   // 短暂等待以证明确实没有读发生
        XCTAssertEqual(reader.readCount, 1)
    }

    func testMinimizeEventReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // AX 最小化事件置脏 → 下一轮必须全读。
        tracker.minimizeForTesting(pid: pidA, cgWindowID: cgWindowA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testNativeParentChangeReopensGateWithoutAWindowIDChange() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])
        ])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)
        let child = AppTrackerCGWindowSnapshot(allWindowIDs: [cgWindowA], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA]], alphaByWindowID: [cgWindowA: 1], parentWindowIDs: [cgWindowA: 999])
        tracker.runPeriodicBatchForTesting(cgSnapshot: child)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
    }

    func testCGSetChangeReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider()
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // 该 pid 的 CG layer-0 集合多了一个窗口 → 必须全读。
        let grown = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB, 99],
            onScreenWindowIDs: [cgWindowA, cgWindowB, 99],
            windowIDsByPID: [pidA: [cgWindowA, 99], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
        tracker.runPeriodicBatchForTesting(cgSnapshot: grown)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testAbsenceClockKeepsReadingEveryBatch() async {
        // phantom 证据必须按原节奏采样：有缺席时钟的 pid 每一轮都读，绝不跳。
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider()
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.isFocused = false
        app.windowsByID[cgWindowA]?.minAbsentSince = Date(timeIntervalSince1970: 10)
        app.windowsByID[cgWindowA]?.absenceEpisodeID = UUID()
        tracker.installFixtureForTesting(app)
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testRefreshDueForcesReadAfterMaxSkipInterval() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            uptimeProvider: { uptime.value }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // 越过 30s 单调时钟兜底 → 强制全读。
        uptime.value = 1031
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testCannotCompleteSharesBackoffAcrossReadSources() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            onScreenWindowIDsProvider: { [id = cgWindowA] in [id] },
            uptimeProvider: { uptime.value }
        )
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)

        uptime.value = 1000.49
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)

        uptime.value = 1000.5
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 2)

        uptime.value = 1001.49
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 2)

        uptime.value = 1001.5
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 3)

        uptime.value = 1003.49
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 3)

        uptime.value = 1003.5
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 4)

        uptime.value = 1005
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 4)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 5)
    }

    func testSuccessfulInventoryResetsTimeoutBackoff() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
                                 onScreenWindowIDsProvider: { [id = cgWindowA] in [id] },
                                 uptimeProvider: { uptime.value })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        await drainInventory(tracker)
        uptime.value = 1000.5
        reader.setResult(.success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Recovered")]), for: pidA)
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "Recovered")

        reader.setResult(.unread(.cannotComplete), for: pidA)
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 3)

        uptime.value = 1001
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 4)
    }

    func testReusedPIDStartsWithoutTheOldProcessTimeoutBackoff() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let process = BatchMutableProcessProvider()
        let tracker = AppTracker(reader: reader, processProvider: process,
                                 cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
                                 onScreenWindowIDsProvider: { [id = cgWindowA] in [id] },
                                 uptimeProvider: { 1000 })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.scheduleEventReadForTesting(pid: pidA, source: .titleChanged)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)

        tracker.terminateForTesting(pid: pidA)
        process.advanceGeneration()
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        reader.setResult(.success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Replacement")]), for: pidA)
        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        await drainInventory(tracker)

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "Replacement")
    }

    // MARK: - 前台缓存（下一轮 A）

    func testFrontmostCacheDrivesActiveHighlightWithoutWorkspaceQuery() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider()
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // 缓存说 pidA 在前台 → 该窗口是 active（真实 frontmostApplication 在测试进程里是别人）。
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .active)

        // 缓存改指别的进程 → 同一个座位立刻降级为 inactive。
        tracker.setFrontmostPIDForTesting(pidB)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    func testPeriodicReconcileRepublishesAfterMissedActivationWithStableWindows() async {
        let snapshot = cgSnapshot()
        let livePID = Mutex(pidA)
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [
                pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
                pidB: .success([makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Window")])
            ]),
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { snapshot },
            frontmostPIDProvider: { livePID.withLock { $0 } }
        )
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
        tracker.runPeriodicBatchForTesting(cgSnapshot: snapshot)
        await drainInventory(tracker)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: snapshot.onScreenWindowIDs)
        let first = WindowID(rawValue: "cgw-\(cgWindowA)")
        let second = WindowID(rawValue: "cgw-\(cgWindowB)")
        XCTAssertEqual(tracker.snapshot.windows[first]?.status, .active)
        XCTAssertEqual(tracker.snapshot.windows[second]?.status, .inactive)

        livePID.withLock { $0 = pidB }
        tracker.runPeriodicReconcileForTesting()
        await drainInventory(tracker)

        XCTAssertEqual(tracker.snapshot.windows[first]?.status, .inactive)
        XCTAssertEqual(tracker.snapshot.windows[second]?.status, .active)
    }

    func testFrontmostCacheKillSwitchIgnoresCachedValue() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            frontmostCacheEnabled: false
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // DOCK_FRONTMOST_CACHE=0：每次真查 NSWorkspace，缓存值不参与判定；
        // 测试进程的真实前台不是 pidA，所以座位不会被点亮。
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    // MARK: - CG 全表复用门控（DOCK_CG_SNAPSHOT_REUSE 默认开）

    private func makeCountingTracker(
        reuseEnabled: Bool = true,
        probeBox: ProbeBox,
        counters: CGCallCounters,
        uptime: UptimeBox? = nil,
        reader: PeriodicBatchReader? = nil,
        table: SnapshotBox? = nil
    ) -> AppTracker {
        let reader = reader ?? PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let snapshot = cgSnapshot()
        let box = uptime
        return AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { counters.noteCapture(); return table?.value ?? snapshot },
            onScreenWindowIDsProvider: { counters.noteProbe(); return probeBox.value },
            cgSnapshotReuseEnabled: reuseEnabled,
            uptimeProvider: { box?.value ?? 1000 }
        )
    }

    func testQuietFrontmostPollReadsOnlyProbeUntilTheFiveSecondFallback() async {
        let counters = CGCallCounters()
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])
        ])
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters,
                                          uptime: uptime, reader: reader)
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(counters.captures, 1)
        XCTAssertEqual(counters.probes, 2)

        uptime.value = 1000.5
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        uptime.value = 1004.5
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(counters.captures, 1)
        XCTAssertEqual(counters.probes, 4)

        uptime.value = 1005
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(counters.probes, 6)
    }

    func testCoalescedBackgroundEventSurvivesInventoryBackoff() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: []), counters: CGCallCounters(),
                                          uptime: uptime, reader: reader)
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowDestroyed)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)
        uptime.value = 1000.49
        tracker.scheduleFrontmostPollForTesting(pid: pidB)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)
        uptime.value = 1000.5
        tracker.scheduleFrontmostPollForTesting(pid: pidB)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 2)
    }

    func testFrontmostCGChangePromotesTheProbeToAFullRead() async {
        let counters = CGCallCounters()
        let probe = ProbeBox(value: [])
        let table = SnapshotBox(value: cgSnapshot())
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "New title")])
        ])
        let tracker = makeCountingTracker(probeBox: probe, counters: counters, reader: reader, table: table)
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.title, "New title")

        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(counters.probes, 3)

        probe.value = [cgWindowA]
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 5)
    }

    func testFailedFrontmostCGCaptureDoesNotPrimeQuietProbe() async {
        let counters = CGCallCounters()
        let table = SnapshotBox(value: .failed)
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])
        ])
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: []), counters: counters,
                                          reader: reader, table: table)
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(counters.captures, 1)
        table.value = cgSnapshot()
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(reader.readCount, 2)

        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 5)
        XCTAssertEqual(reader.readCount, 2)
    }

    func testFullCaptureUsesAProbeTakenAfterAXInsteadOfTheAdmissionProbe() async {
        let counters = CGCallCounters()
        let currentID = cgWindowA
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: currentID, title: "Current")])
        ])
        let table = cgSnapshot()
        let tracker = AppTracker(
            reader: reader, processProvider: BatchFixedProcessProvider(), cgSnapshotProvider: { table },
            onScreenWindowIDsProvider: {
                counters.noteProbe()
                return counters.probes == 1 ? [] : [currentID]
            },
            uptimeProvider: { 1000 }
        )
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: currentID))
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(tracker.cgSnapshotCacheForTesting()?.probeIDs, [currentID])
    }

    func testUnavailableFrontmostProbeIsDistinctFromAValidEmptySample() async {
        let counters = CGCallCounters()
        let probe = ProbeBox(value: [])
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])
        ])
        let tracker = makeCountingTracker(probeBox: probe, counters: counters, reader: reader)
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 1)

        probe.value = nil
        tracker.scheduleFrontmostPollForTesting(pid: pidA)
        await drainInventory(tracker)
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 4)
    }

    private func runEventRead(_ tracker: AppTracker) async {
        tracker.scheduleEventReadForTesting(pid: pidA, source: .frontmostPoll)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
    }

    func testQuietSecondEventReadReusesCachedTable() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)          // 无缓存 → 探针 + 现拍，缓存接上
        XCTAssertNotNil(tracker.cgSnapshotCacheForTesting())
        let capturesAfterFirst = counters.captures

        await runEventRead(tracker)          // 安静 tick：探针相同 → 复用，全拍数不增
        XCTAssertEqual(counters.captures, capturesAfterFirst)
    }

    func testProbeChangeForcesFreshCapture() async {
        let counters = CGCallCounters()
        let probeBox = ProbeBox(value: [cgWindowA])
        let tracker = makeCountingTracker(probeBox: probeBox, counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        probeBox.value = [cgWindowA, cgWindowB]   // on-screen 集变了（如切了标签）
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testEventGenerationBumpForcesFreshCapture() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        tracker.bumpCGEventGenerationForTesting()  // 期间来了 AX/workspace 事件
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testCacheExpiryForcesFreshCapture() async {
        let counters = CGCallCounters()
        let uptime = UptimeBox(value: 1000)
        let tracker = makeCountingTracker(
            probeBox: ProbeBox(value: [cgWindowA]), counters: counters, uptime: uptime
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        uptime.value = 1000 + CGSnapshotReuseDecision.defaultMaxCacheAge + 0.1
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testKillSwitchCapturesEveryTimeAndNeverProbes() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(
            reuseEnabled: false, probeBox: ProbeBox(value: [cgWindowA]), counters: counters
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        await runEventRead(tracker)
        // 与关门前逐位一致：每次事件读各现拍一张。探针计数只可能来自 rebuildSnapshot 的
        // on-screen 兜底（本用例 seats 不变、不重建），事件读路径必须一次探针都没拍。
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 0)
        XCTAssertNil(tracker.cgSnapshotCacheForTesting())
    }

    /// A cached table may not veto: once AX lists an id the cache holds as below-normal-layer, the
    /// read captures fresh. Every other reuse condition holds here (observer active, fixed uptime,
    /// no event, unchanged probe), so only that check can cause the extra capture.
    func testCachedBelowLayerVetoForcesFreshCaptureAndSeatsRaisedWindow() async {
        let counters = CGCallCounters()
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([
                makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window"),
                makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: "Raised"),
            ]),
        ])
        let table = SnapshotBox(value: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA]], alphaByWindowID: [:],
            belowNormalLayerWindowIDs: [cgWindowB]
        ))
        let onScreen: Set<CGWindowID> = [cgWindowA]
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { counters.noteCapture(); return table.value },
            onScreenWindowIDsProvider: { counters.noteProbe(); return onScreen },
            cgSnapshotReuseEnabled: true,
            uptimeProvider: { 1000 }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)          // primes the cache; B is on the desktop layer → no seat
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        let tokenA = tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.token
        let capturesAfterFirst = counters.captures

        // B rises to layer 0 while off-screen: the layer-0 on-screen probe does not change.
        table.value = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA, cgWindowB]], alphaByWindowID: [:]
        )
        await runEventRead(tracker)

        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.token, tokenA)
    }

    func testCachedChildCannotRetireARootWhenPublishedWindowsAreMissing() async {
        for readable in [false, true] {
            let counters = CGCallCounters()
            let uptime = UptimeBox(value: 1000)
            let reader = PeriodicBatchReader(resultsByPID: [
                pidA: readable ? .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]) : .unread(.failure),
                pidB: .success([makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Window")])
            ])
            let table = SnapshotBox(value: AppTrackerCGWindowSnapshot(
                allWindowIDs: [cgWindowA, cgWindowB], onScreenWindowIDs: [cgWindowA, cgWindowB],
                windowIDsByPID: [pidA: [cgWindowA], pidB: [cgWindowB]], alphaByWindowID: [:],
                parentWindowIDs: [cgWindowA: cgWindowB, cgWindowB: 0]))
            let child = table.value
            let onScreen: Set<CGWindowID> = [cgWindowA, cgWindowB]
            let tracker = AppTracker(reader: reader, processProvider: BatchFixedProcessProvider(),
                cgSnapshotProvider: { counters.noteCapture(); return table.value },
                onScreenWindowIDsProvider: { counters.noteProbe(); return onScreen },
                cgSnapshotReuseEnabled: true, uptimeProvider: { uptime.value })
            defer { tracker.stop() }
            tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
            tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))
            tracker.setObserverActiveForTesting(pid: pidA, active: true)
            tracker.setObserverActiveForTesting(pid: pidB, active: true)
            tracker.scheduleEventReadForTesting(pid: pidB, source: .frontmostPoll)
            await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidB) }
            XCTAssertEqual(counters.captures, 1)
            let token = tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.token
            table.value = AppTrackerCGWindowSnapshot(allWindowIDs: onScreen, onScreenWindowIDs: onScreen,
                windowIDsByPID: [pidA: [cgWindowA], pidB: [cgWindowB]], alphaByWindowID: [:],
                parentWindowIDs: [cgWindowA: 0, cgWindowB: 0])
            await runEventRead(tracker)
            XCTAssertEqual(counters.captures, 2, "readable=\(readable)")
            XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.token, token)
            table.value = child
            await runEventRead(tracker)
            XCTAssertEqual(counters.captures, 2)
            XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
            uptime.value = 1000 + CGSnapshotReuseDecision.defaultMaxCacheAge + 0.1
            await runEventRead(tracker)
            XCTAssertEqual(counters.captures, 3)
            XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
        }
    }

    /// Accepted cost, pinned: a failed capture cannot veto, so a desktop-layer window is seated for
    /// that round and released by the next successful one.
    func testFailedCaptureSeatsDesktopLayerWindowUntilNextSuccessfulRound() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([
                makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window"),
                makeSnapshot(pid: pidA, cgWindowID: cgWindowB, title: ""),
            ]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider()
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.runPeriodicBatchForTesting(cgSnapshot: .failed)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])

        tracker.runPeriodicBatchForTesting(cgSnapshot: AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA], onScreenWindowIDs: [cgWindowA],
            windowIDsByPID: [pidA: [cgWindowA]], alphaByWindowID: [:],
            belowNormalLayerWindowIDs: [cgWindowB]
        ))
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowB])
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
    }

    // MARK: - Fixtures

    /// 关窗口事件必须走限时后台读，不能在主 actor 上触发不限时读（被关窗口的 App 卡住时主线程会冻 ~12s）。
    func testWindowDestroyedUsesTimedBackgroundReadNeverUntimedMainActorRead() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let emptyCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { emptyCG }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.destroyForTesting(pid: pidA, cgWindowID: cgWindowA)

        XCTAssertEqual(reader.untimedReadCount, 0, "destroy 处理器不得在主 actor 上做不限时 AX 读")
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(reader.untimedReadCount, 0)
        // AX 空 + CG 全列表已无该窗口 → 座位真删。
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
    }

    /// A window is ordered out (destroy notification, still in CG) and, before its follow-up read
    /// lands, another window of the same app is minimized. The minimize invalidates the in-flight
    /// read; a fresh read must still follow, or the destroy's 3s tombstone expires unreconciled and
    /// the hidden window's seat is held for the app's lifetime.
    func testMinimizeDuringDestroyFollowUpReadStillReconcilesTheDestroy() async {
        let hidden: CGWindowID = 91
        let minimized: CGWindowID = 92
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: minimized, title: "Other")])],
            blocksTimedReads: true
        )
        let bothInCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [hidden, minimized],
            onScreenWindowIDs: [minimized],
            windowIDsByPID: [pidA: [hidden, minimized]],
            alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { bothInCG }
        )
        var app = makeApp(pid: pidA, cgWindowID: hidden)
        app.windowsByID[minimized] = WindowEntry(
            cgWindowID: minimized, token: "tabgrp-\(pidA)-s2", title: "Other",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false, isFocused: false, everSeenVisible: true
        )
        app.windowOrder.append(minimized)
        tracker.installFixtureForTesting(app)

        tracker.destroyForTesting(pid: pidA, cgWindowID: hidden)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        tracker.minimizeForTesting(pid: pidA, cgWindowID: minimized)

        reader.releaseOne()   // the destroy's read lands as skipped (generation moved)
        await waitUntil { reader.readCount == 2 }
        reader.releaseOne()   // the follow-up read
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[hidden])
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[minimized])
    }

    private func cgSnapshot() -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB],
            onScreenWindowIDs: [cgWindowA, cgWindowB],
            windowIDsByPID: [pidA: [cgWindowA], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
    }

    private func makeApp(pid: pid_t, cgWindowID: CGWindowID) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false,
            isFocused: true,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture\(pid)",
            appName: "Fixture\(pid)",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false
        )
    }

    private func makeSnapshot(
        pid: pid_t, cgWindowID: CGWindowID, title: String, element: AXUIElement? = nil,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 500, height: 400)
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID,
            titleRead: .value(title),
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: false,
            isFocusedWindow: true,
            element: element ?? AXUIElementCreateApplication(pid)
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func drainInventory(_ tracker: AppTracker) async {
        while !tracker.pendingInventoryWorkForTesting.isEmpty {
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
        }
    }
}

/// 可注入按 pid 定制结果的限时读探针；可选在读中阻塞（模拟批读在途窗口）。
private final class SelectivePeriodicReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blockedPID: pid_t
    private let firstReadGatePID: pid_t?
    private let firstReadSemaphore = DispatchSemaphore(value: 0)
    private let results: [pid_t: [AXWindowSnapshot]]
    private let unreadPIDs: Set<pid_t>
    private let returnsAllSnapshots: Bool
    private var counts: [pid_t: Int] = [:]
    private var blocked = false
    private var finishedBlocked = false
    private var firstReadBlocked = false

    init(blockedPID: pid_t, results: [pid_t: [AXWindowSnapshot]], firstReadGatePID: pid_t? = nil,
         unreadPIDs: Set<pid_t> = [], returnsAllSnapshots: Bool = false) {
        self.blockedPID = blockedPID
        self.results = results
        self.firstReadGatePID = firstReadGatePID
        self.unreadPIDs = unreadPIDs
        self.returnsAllSnapshots = returnsAllSnapshots
    }

    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    var finishedBlockedRead: Bool { lock.lock(); defer { lock.unlock() }; return finishedBlocked }
    var isFirstReadBlocked: Bool { lock.lock(); defer { lock.unlock() }; return firstReadBlocked }
    func reads(for pid: pid_t) -> Int { lock.lock(); defer { lock.unlock() }; return counts[pid, default: 0] }
    func release() { semaphore.signal() }
    func releaseFirstRead() { firstReadSemaphore.signal() }
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .success([]) }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        counts[pid, default: 0] += 1
        let count = counts[pid, default: 0]
        if pid == blockedPID { blocked = true }
        let holdFirstRead = pid == firstReadGatePID && count == 1
        if holdFirstRead { firstReadBlocked = true }
        lock.unlock()
        if holdFirstRead { firstReadSemaphore.wait() }
        if pid == blockedPID {
            semaphore.wait()
            lock.lock()
            finishedBlocked = true
            lock.unlock()
        }
        if unreadPIDs.contains(pid) { return .unread(.cannotComplete) }
        guard let snapshots = results[pid], !snapshots.isEmpty else { return .success([]) }
        if returnsAllSnapshots { return .success(snapshots) }
        return .success([snapshots[min(count - 1, snapshots.count - 1)]])
    }
}

private final class PeriodicBatchReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var untimedCount = 0
    private var resultsByPID: [pid_t: AXWindowReadResult]
    private let blocksTimedReads: Bool

    init(resultsByPID: [pid_t: AXWindowReadResult], blocksTimedReads: Bool = false) {
        self.resultsByPID = resultsByPID
        self.blocksTimedReads = blocksTimedReads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func releaseOne() {
        semaphore.signal()
    }

    func setResult(_ result: AXWindowReadResult, for pid: pid_t) {
        lock.lock()
        resultsByPID[pid] = result
        lock.unlock()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }

    var untimedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return untimedCount
    }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        lock.lock()
        defer { lock.unlock() }
        untimedCount += 1
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        count += 1
        let result = resultsByPID[pid] ?? .unread(.cannotComplete)
        lock.unlock()
        if blocksTimedReads { semaphore.wait() }
        return result
    }
}

private final class CGCallCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var captureCount = 0
    private var probeCount = 0

    func noteCapture() { lock.lock(); captureCount += 1; lock.unlock() }
    func noteProbe() { lock.lock(); probeCount += 1; lock.unlock() }

    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var probes: Int { lock.lock(); defer { lock.unlock() }; return probeCount }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<CGWindowID>?

    init(value: Set<CGWindowID>?) { self.storage = value }

    var value: Set<CGWindowID>? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AppTrackerCGWindowSnapshot

    init(value: AppTrackerCGWindowSnapshot) { self.storage = value }

    var value: AppTrackerCGWindowSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class UptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(value: TimeInterval) {
        self.storage = value
    }

    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private struct BatchFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}

private final class BatchMutableProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int64 = 1

    func advanceGeneration() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        lock.lock()
        let current = generation
        lock.unlock()
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: current,
            startTimeUsec: 0,
            bundleID: bundleID
        )
    }
}
