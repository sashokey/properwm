import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

private final class LifecycleReader: AppTrackerWindowReading, @unchecked Sendable {
    struct State {
        var count = 0
        var usedMainThread = false
    }
    let state = Mutex(State())
    let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { read(pid) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { read(pid) }

    private func read(_ pid: pid_t) -> AXWindowReadResult {
        let index = state.withLock { state in
            defer { state.count += 1 }
            state.usedMainThread = state.usedMainThread || Thread.isMainThread
            return state.count
        }
        guard gates.indices.contains(index) else { return .unread(.cannotComplete) }
        _ = gates[index].wait(timeout: .now() + 3)
        return .success([AXWindowSnapshot(pid: pid, cgWindowID: 77, titleRead: .value("Read \(index)"),
            bounds: CGRect(x: 40, y: 40, width: 640, height: 480), role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String, isMinimized: false, isFocusedWindow: false,
            element: AXUIElementCreateApplication(pid))])
    }
}

private final class LifecycleProcess: AppTrackerProcessProviding, Sendable {
    let generation = Mutex(Int64(1))
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: generation.withLock { $0 }, startTimeUsec: 0, bundleID: bundleID)
    }
}

@MainActor
final class InventoryLifecycleTests: XCTestCase {
    func testClosedHeldSeatsReleaseTheirDiagnosticEpisodesWhileTheApplicationKeepsRunning() throws {
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: true, directoryURL: directory,
                                                                 maxFileSize: 1_000_000, archiveCount: 1))
        let tracker = AppTracker(inventoryLog: log, reader: FocusLifecycleReader(blockFirst: false),
                                 processProvider: LifecycleProcess(), cgSnapshotProvider: { .failed })
        defer { tracker.stop(); try? FileManager.default.removeItem(at: directory) }
        for index in 0..<5 {
            let id = CGWindowID(77 + index)
            var seat = inventorySeat(id, token: "held-\(index)", bounds: inventoryFrame, minimized: true)
            seat.minAbsentSince = Date(timeIntervalSince1970: 80)
            seat.absenceEpisodeID = UUID()
            tracker.installFixtureForTesting(inventoryApp(entries: [seat]))
            reconcileInventory(tracker, eligible: [], cg: inventoryCG(ids: [id]))
            XCTAssertEqual(try heldEpisodeCount(tracker), 1)
            reconcileInventory(tracker, eligible: [], cg: inventoryCG(ids: []))
            XCTAssertEqual(tracker.fixtureAppForTesting(pid: inventoryPID)?.windowsByID.count, 0)
            XCTAssertEqual(try heldEpisodeCount(tracker), 0)
        }
    }

    func testIndependentMinimizedAdmissionDoesNotWriteUnconditionalDebugOutput() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(inventoryApp(entries: []))
        let output = try capturedStandardOutput {
            reconcileInventory(tracker, eligible: [
                inventoryWindow(77, bounds: inventoryFrame, minimized: true),
                inventoryWindow(88, bounds: inventoryFrame, minimized: true),
                inventoryWindow(99, bounds: inventoryFrame, minimized: true)
            ], cg: inventoryCG(ids: [77, 88, 99]))
        }
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: inventoryPID)?.windowOrder, [77, 88, 99])
        XCTAssertFalse(output.contains("[tabfold]"))
    }

    private func heldEpisodeCount(_ tracker: AppTracker) throws -> Int {
        let deduplicator = try XCTUnwrap(Mirror(reflecting: tracker).children.first {
            $0.label == "heldLogDeduplicator"
        }?.value)
        let storage = try XCTUnwrap(Mirror(reflecting: deduplicator).children.first {
            $0.label == "reasonsByEpisode"
        }?.value)
        return Mirror(reflecting: storage).children.count
    }

    private func capturedStandardOutput(_ operation: () -> Void) throws -> String {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let pipe = Pipe()
        defer { dup2(saved, STDOUT_FILENO); close(saved) }
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        operation()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        return String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
    }

    func testMovingEitherOverlappingIndependentWindowPreservesBothSeatsAndTokens() throws {
        for movedID: CGWindowID in [77, 88] {
            let tracker = inventoryTracker()
            defer { tracker.stop() }
            let original = inventoryFrame
            let moved = original.offsetBy(dx: 260, dy: 90)
            tracker.installFixtureForTesting(inventoryApp(entries: [
                inventorySeat(77, token: "independent-X", bounds: original),
                inventorySeat(88, token: "independent-Y", bounds: original)
            ]))
            for _ in 0..<3 {
                reconcileInventory(tracker, eligible: [
                    inventoryWindow(77, bounds: movedID == 77 ? moved : original),
                    inventoryWindow(88, bounds: movedID == 88 ? moved : original)
                ], cg: inventoryCG(ids: [77, 88], onScreen: [77, 88]))
                let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
                XCTAssertEqual(app.windowOrder, [77, 88])
                XCTAssertEqual(app.windowsByID.count, 2)
                XCTAssertEqual(app.windowsByID[77]?.token, "independent-X")
                XCTAssertEqual(app.windowsByID[88]?.token, "independent-Y")
                XCTAssertEqual(app.windowsByID[movedID]?.bounds, moved)
            }
        }
    }

    func testIndependentWindowEnteringVacatedFrameDoesNotTakeAnotherSeatsToken() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(inventoryApp(entries: [
            inventorySeat(77, token: "independent-X", bounds: inventoryFrame),
            inventorySeat(88, token: "independent-Y", bounds: inventoryFrame.offsetBy(dx: 500, dy: 0))
        ]))
        for _ in 0..<3 {
            reconcileInventory(tracker, eligible: [
                inventoryWindow(77, bounds: inventoryFrame.offsetBy(dx: 200, dy: 100)),
                inventoryWindow(88, bounds: inventoryFrame)
            ], cg: inventoryCG(ids: [77, 88], onScreen: [77, 88]))
            let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
            XCTAssertEqual(app.windowOrder, [77, 88])
            XCTAssertEqual(app.windowsByID[77]?.token, "independent-X")
            XCTAssertEqual(app.windowsByID[88]?.token, "independent-Y")
        }
    }

    func testIndependentMinimizedWindowsAtStartupKeepSeatsWithMatchingFramesOrSizes() throws {
        for secondBounds in [inventoryFrame, inventoryFrame.offsetBy(dx: 300, dy: 80)] {
            let tracker = inventoryTracker()
            defer { tracker.stop() }
            tracker.installFixtureForTesting(inventoryApp(entries: []))
            var originalTokens: [String] = []
            for round in 0..<3 {
                reconcileInventory(tracker, eligible: [
                    inventoryWindow(77, bounds: inventoryFrame, minimized: true),
                    inventoryWindow(88, bounds: secondBounds, minimized: true)
                ], cg: inventoryCG(ids: [77, 88]))
                let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
                XCTAssertEqual(app.windowOrder, [77, 88])
                XCTAssertEqual(app.windowsByID.count, 2)
                XCTAssertEqual(Set(app.windowsByID.values.map(\.token)).count, 2)
                XCTAssertTrue(app.windowsByID.values.allSatisfy(\.isMinimized))
                if round == 0 { originalTokens = app.windowOrder.compactMap { app.windowsByID[$0]?.token } }
                else { XCTAssertEqual(app.windowOrder.compactMap { app.windowsByID[$0]?.token }, originalTokens) }
            }
        }
    }

    func testObservedNativeTabSwitchStillFoldsKnownMembersAfterMoveAndMinimize() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(inventoryApp(entries: [
            inventorySeat(77, token: "native-tab-seat", bounds: inventoryFrame)
        ]))
        reconcileInventory(tracker, eligible: [inventoryWindow(88, bounds: inventoryFrame)],
                           cg: inventoryCG(ids: [77, 88], onScreen: [88]))
        let switched = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
        XCTAssertEqual(switched.windowOrder, [88])
        XCTAssertEqual(switched.windowsByID[88]?.formerCgIDs, [77])
        let moved = CGRect(x: 450, y: 220, width: 1100, height: 710)
        for _ in 0..<3 {
            reconcileInventory(tracker, eligible: [
                inventoryWindow(77, bounds: inventoryFrame, minimized: true),
                inventoryWindow(88, bounds: moved, minimized: true)
            ], cg: inventoryCG(ids: [77, 88]))
            let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
            XCTAssertEqual(app.windowOrder, [88])
            XCTAssertEqual(app.windowsByID[88]?.token, "native-tab-seat")
            XCTAssertEqual(app.windowsByID[88]?.formerCgIDs, [77])
        }
    }

    func testIndependentMinimizedWindowOmittedBeforeSiblingAdmissionKeepsItsSeatWhenBothReturn() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(inventoryApp(entries: [
            inventorySeat(77, token: "independent-X", bounds: inventoryFrame, minimized: true)
        ]))
        reconcileInventory(tracker, eligible: [inventoryWindow(88, bounds: inventoryFrame, minimized: true)],
                           cg: inventoryCG(ids: [77, 88]))
        let omitted = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
        XCTAssertEqual(omitted.windowOrder, [77, 88])
        XCTAssertEqual(omitted.windowsByID[77]?.token, "independent-X")
        XCTAssertFalse(omitted.windowsByID[88]?.formerCgIDs.contains(77) ?? true)
        let siblingToken = omitted.windowsByID[88]?.token
        for _ in 0..<3 {
            reconcileInventory(tracker, eligible: [
                inventoryWindow(77, bounds: inventoryFrame, minimized: true),
                inventoryWindow(88, bounds: inventoryFrame, minimized: true)
            ], cg: inventoryCG(ids: [77, 88]))
            let returned = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
            XCTAssertEqual(returned.windowOrder, [77, 88])
            XCTAssertEqual(returned.windowsByID[77]?.token, "independent-X")
            XCTAssertEqual(returned.windowsByID[88]?.token, siblingToken)
        }
    }

    func testNativeTabTearOutRetainsOriginalSeatAndAllocatesIndependentWindow() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(inventoryApp(entries: [
            inventorySeat(77, token: "native-tab-seat", bounds: inventoryFrame)
        ]))
        reconcileInventory(tracker, eligible: [
            inventoryWindow(77, bounds: inventoryFrame.offsetBy(dx: 300, dy: 0)),
            inventoryWindow(88, bounds: inventoryFrame)
        ], cg: inventoryCG(ids: [77, 88], onScreen: [77, 88]))
        let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
        XCTAssertEqual(app.windowOrder, [88, 77])
        XCTAssertEqual(app.windowsByID[88]?.token, "native-tab-seat")
        XCTAssertNotEqual(app.windowsByID[77]?.token, "native-tab-seat")
        XCTAssertFalse(app.windowsByID[88]?.formerCgIDs.contains(77) ?? true)
    }

    func testFailedCGCapturePreservesAXAbsentMinimizedSeatHistoryAndCachedHandle() throws {
        let tracker = inventoryTracker()
        let cache = AXElementCache.shared
        defer { tracker.stop(); cache.removeAll(pid: inventoryPID) }
        var seat = inventorySeat(77, token: "held-minimized", bounds: inventoryFrame, minimized: true)
        seat.formerCgIDs = [91]
        seat.minAbsentSince = Date(timeIntervalSince1970: 10)
        seat.absenceEpisodeID = UUID()
        var app = inventoryApp(entries: [seat])
        app.shadowTabCgIDs = [92]
        tracker.installFixtureForTesting(app)
        let handle = AXUIElementCreateApplication(inventoryPID)
        cache.store(pid: inventoryPID, cgWindowID: 77, element: handle)
        for cg in [AppTrackerCGWindowSnapshot.failed, inventoryCG(ids: [77, 91, 92])] {
            reconcileInventory(tracker, eligible: [], cg: cg)
            let after = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
            XCTAssertEqual(after.windowOrder, [77])
            XCTAssertEqual(after.windowsByID[77]?.token, "held-minimized")
            XCTAssertEqual(after.windowsByID[77]?.formerCgIDs, [91])
            XCTAssertEqual(after.windowsByID[77]?.minAbsentSince, seat.minAbsentSince)
            XCTAssertEqual(after.windowsByID[77]?.absenceEpisodeID, seat.absenceEpisodeID)
            XCTAssertEqual(after.shadowTabCgIDs, [92])
            XCTAssertEqual(cache.element(pid: inventoryPID, cgWindowID: 77).map { CFEqual($0, handle) }, true)
            tracker.rebuildSnapshotForTesting()
            XCTAssertEqual(tracker.snapshot.windows.values.map(\.cgWindowID), [77])
        }
    }

    func testFailedCGCaptureAcceptsPositiveAXUpdatesWithoutPurgingOtherSeatsOrHistory() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop(); AXElementCache.shared.removeAll(pid: inventoryPID) }
        var visible = inventorySeat(77, token: "visible-seat", bounds: inventoryFrame)
        visible.formerCgIDs = [91]
        var app = inventoryApp(entries: [visible,
            inventorySeat(88, token: "minimized-seat", bounds: inventoryFrame.offsetBy(dx: 600, dy: 0), minimized: true)])
        app.shadowTabCgIDs = [92]
        tracker.installFixtureForTesting(app)
        reconcileInventory(tracker, eligible: [
            inventoryWindow(77, bounds: inventoryFrame.offsetBy(dx: 30, dy: 20), title: "Updated"),
            inventoryWindow(99, bounds: inventoryFrame.offsetBy(dx: 600, dy: 0), title: "New")
        ], cg: .failed)
        let after = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
        XCTAssertEqual(after.windowOrder, [77, 88, 99])
        XCTAssertEqual(after.windowsByID[77]?.title, "Updated")
        XCTAssertEqual(after.windowsByID[77]?.token, "visible-seat")
        XCTAssertEqual(after.windowsByID[77]?.formerCgIDs, [91])
        XCTAssertEqual(after.windowsByID[88]?.token, "minimized-seat")
        XCTAssertEqual(after.windowsByID[99]?.title, "New")
        XCTAssertEqual(after.shadowTabCgIDs, [92])
        XCTAssertNotNil(AXElementCache.shared.element(pid: inventoryPID, cgWindowID: 99))
    }

    func testKnownNativeTabSwitchPreservesItsSeatDuringFailedCGAndRecovery() throws {
        let tracker = inventoryTracker()
        defer { tracker.stop(); AXElementCache.shared.removeAll(pid: inventoryPID) }
        tracker.installFixtureForTesting(inventoryApp(entries: [
            inventorySeat(77, token: "native-tab-seat", bounds: inventoryFrame)
        ]))
        reconcileInventory(tracker, eligible: [inventoryWindow(88, bounds: inventoryFrame)],
                           cg: inventoryCG(ids: [77, 88], onScreen: [88]))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: inventoryPID)?.windowsByID[88]?.formerCgIDs, [77])
        for cg in [AppTrackerCGWindowSnapshot.failed, inventoryCG(ids: [77, 88], onScreen: [77])] {
            reconcileInventory(tracker, eligible: [inventoryWindow(77, bounds: inventoryFrame)], cg: cg)
            let app = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
            XCTAssertEqual(app.windowOrder, [77])
            XCTAssertEqual(app.windowsByID[77]?.token, "native-tab-seat")
            XCTAssertEqual(app.windowsByID[77]?.formerCgIDs, [88])
        }
    }

    func testSuccessfulEmptyCGCaptureRemovesClosedSeatAndCachedHandle() throws {
        let tracker = inventoryTracker()
        let cache = AXElementCache.shared
        defer { tracker.stop(); cache.removeAll(pid: inventoryPID) }
        tracker.installFixtureForTesting(inventoryApp(entries: [
            inventorySeat(77, token: "closed-seat", bounds: inventoryFrame, minimized: true)
        ]))
        cache.store(pid: inventoryPID, cgWindowID: 77, element: AXUIElementCreateApplication(inventoryPID))
        reconcileInventory(tracker, eligible: [], cg: inventoryCG(ids: []))
        let after = try XCTUnwrap(tracker.fixtureAppForTesting(pid: inventoryPID))
        XCTAssertTrue(after.windowOrder.isEmpty)
        XCTAssertTrue(after.windowsByID.isEmpty)
        XCTAssertNil(cache.element(pid: inventoryPID, cgWindowID: 77))
    }

    private var inventoryPID: pid_t { 45454 }
    private var inventoryFrame: CGRect { CGRect(x: 60, y: 40, width: 800, height: 600) }

    private func inventoryTracker() -> AppTracker {
        AppTracker(reader: FocusLifecycleReader(blockFirst: false), processProvider: LifecycleProcess(),
                   cgSnapshotProvider: { .failed }, onScreenWindowIDsProvider: { [] })
    }

    private func inventoryApp(entries: [WindowEntry]) -> AppEntry {
        AppEntry(pid: inventoryPID, bundleIdentifier: "test.Inventory", appName: "Inventory",
                 activationPolicy: .regular, executablePath: nil,
                 windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
                 windowOrder: entries.map(\.cgWindowID), isHidden: false)
    }

    private func inventorySeat(_ id: CGWindowID, token: String, bounds: CGRect, minimized: Bool = false) -> WindowEntry {
        WindowEntry(cgWindowID: id, token: token, title: "Window \(id)", bounds: bounds,
                    isMinimized: minimized, isFocused: false, everSeenVisible: true)
    }

    private func inventoryWindow(_ id: CGWindowID, bounds: CGRect, minimized: Bool = false,
                                 title: String? = nil) -> AXWindowSnapshot {
        AXWindowSnapshot(pid: inventoryPID, cgWindowID: id, titleRead: .value(title ?? "Window \(id)"),
                         bounds: bounds, role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                         isMinimized: minimized, isFocusedWindow: false, element: AXUIElementCreateApplication(inventoryPID))
    }

    private func inventoryCG(ids: Set<CGWindowID>, onScreen: Set<CGWindowID> = []) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(allWindowIDs: ids, onScreenWindowIDs: onScreen,
                                   windowIDsByPID: [inventoryPID: ids], alphaByWindowID: [:])
    }

    private func reconcileInventory(_ tracker: AppTracker, eligible: [AXWindowSnapshot], cg: AppTrackerCGWindowSnapshot) {
        tracker.reconcileFixtureForTesting(pid: inventoryPID, cgSnapshot: cg, now: Date(timeIntervalSince1970: 100),
                                           eligible: eligible, readOutcome: .success(count: eligible.count))
    }

    func testFocusedWindowReadDoesNotEnumerateWindowsOrReadTheirContent() {
        let desktop = BehaviorDesktop()
        let attributes = Mutex<[String]>([])
        desktop.state.withLock {
            $0.focused = 1002
            $0.beforeRead = { name in attributes.withLock { $0.append(name) } }
        }
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: OperationCancellation()).result, .window(1002))
        XCTAssertEqual(attributes.withLock { $0 }, [kAXFocusedWindowAttribute as String])
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        desktop.state.withLock { $0.focused = nil }
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: OperationCancellation()).result, .none)
    }

    func testCancelledFocusedWindowReadCannotPublishAnIdentity() {
        let desktop = BehaviorDesktop()
        let cancellation = OperationCancellation()
        desktop.state.withLock { $0.beforeRead = { _ in cancellation.cancel() } }
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: cancellation).result, .unread(.cannotComplete))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testFocusedWindowReadRejectsAnElementWhoseOwnerChangedDuringCapture() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.focused = 1002
            $0.beforeRead = { [weak desktop] attribute in
                guard attribute == kAXFocusedWindowAttribute as String else { return }
                desktop?.state.withLock { state in
                    guard let old = state.windows[1002] else { return }
                    state.windows[1002] = WindowRecord(id: old.id, appID: old.appID, pid: -42000,
                        bundleIdentifier: old.bundleIdentifier, title: old.title, bounds: old.bounds,
                        status: old.status, cgWindowID: old.cgWindowID)
                }
            }
        }
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: OperationCancellation()).result, .unread(.invalidUIElement))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    private func focusFixtureApp(_ focused: CGWindowID? = nil, title: String = "Original") -> AppEntry {
        let entries = [UInt32(77), 88].map { id in
            WindowEntry(cgWindowID: id, token: "focus-\(id)", title: title,
                        bounds: CGRect(x: CGFloat(id), y: 30, width: 600, height: 500),
                        isMinimized: false, isFocused: id == focused)
        }
        return AppEntry(pid: 42, bundleIdentifier: "test.focus", appName: "Focus", activationPolicy: .regular,
            executablePath: nil, windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
            windowOrder: [77, 88], isHidden: false)
    }

    private func focusTracker(_ reader: FocusLifecycleReader, process: LifecycleProcess = LifecycleProcess(),
                              focused: CGWindowID? = nil) -> AppTracker {
        let tracker = AppTracker(reader: reader, processProvider: process, onScreenWindowIDsProvider: { [77, 88] })
        tracker.installFixtureForTesting(focusFixtureApp(focused))
        tracker.setFrontmostPIDForTesting(42)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77, 88])
        return tracker
    }

    private func waitForFocus(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testFocusBurstCoalescesWithoutPublishingAnOlderFocusedWindow() async {
        let reader = FocusLifecycleReader()
        let tracker = focusTracker(reader)
        defer { reader.gate.signal(); tracker.stop() }
        var observed: [CGWindowID] = []
        let subscription = tracker.$snapshot.sink { snapshot in
            if let id = snapshot.windows.values.first(where: { $0.status == .active })?.cgWindowID { observed.append(id) }
        }
        defer { subscription.cancel() }
        tracker.handleFocusedWindowChanged(pid: 42)
        await waitForFocus { reader.state.withLock { $0.reads == 1 } }
        reader.state.withLock { $0.result = .window(88) }
        for _ in 0..<20 { tracker.handleFocusedWindowChanged(pid: 42) }
        XCTAssertEqual(reader.state.withLock { $0.reads }, 1)
        reader.gate.signal()
        await waitForFocus { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.status == .active }
        XCTAssertEqual(reader.state.withLock { $0.reads }, 2)
        XCTAssertFalse(observed.contains(77))
        XCTAssertFalse(reader.state.withLock { $0.usedMainThread })
    }

    func testStopAndProcessReplacementRejectLateFocusedWindowReads() async {
        for replace in [false, true] {
            let reader = FocusLifecycleReader()
            let process = LifecycleProcess()
            let tracker = focusTracker(reader, process: process)
            defer { reader.gate.signal(); tracker.stop() }
            tracker.handleFocusedWindowChanged(pid: 42)
            await waitForFocus { reader.state.withLock { $0.reads == 1 } }
            let pending = tracker.pendingInventoryWorkForTesting
            if replace {
                tracker.handleAppTerminated(pid: 42)
                process.generation.withLock { $0 += 1 }
                tracker.installFixtureForTesting(focusFixtureApp(title: "Replacement"))
                tracker.setFrontmostPIDForTesting(42)
                tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77, 88])
            } else { tracker.stop() }
            reader.gate.signal()
            for task in pending { await task.value }
            XCTAssertFalse(tracker.snapshot.windows.values.contains { $0.status == .active })
            if replace { XCTAssertEqual(Set(tracker.snapshot.windows.values.map(\.title)), ["Replacement"]) }
            else { XCTAssertTrue(tracker.snapshot.windows.isEmpty) }
        }
    }

    func testUnavailableFocusPreservesHighlightAndConfirmedNoWindowClearsIt() async {
        let reader = FocusLifecycleReader(blockFirst: false)
        reader.state.withLock { $0.result = .unread(.cannotComplete) }
        let tracker = focusTracker(reader, focused: 77)
        defer { tracker.stop() }
        tracker.handleFocusedWindowChanged(pid: 42)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.status, .active)
        reader.state.withLock { $0.result = .none }
        tracker.handleFocusedWindowChanged(pid: 42)
        await waitForFocus { !tracker.snapshot.windows.values.contains { $0.status == .active } }
        XCTAssertEqual(reader.state.withLock { $0.reads }, 2)
    }

    func testAFullReadThatCapturesFocusLaterCanAdvanceTheFocusedWindow() async {
        let desktop = BehaviorDesktop()
        let gate = FocusListGate()
        desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 1002], onScreenWindowIDs: [1001, 1002],
            windowIDsByPID: [-41000: [1001, 1002]], alphaByWindowID: [1001: 1, 1002: 1])
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 1002] })
        let entries = [UInt32(1001), 1002].map { id in
            WindowEntry(cgWindowID: id, token: "tabgrp-\(id)", title: "Window \(id)",
                        bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050), isMinimized: false, isFocused: false,
                        everSeenVisible: true)
        }
        tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Editor", appName: "Editor",
            activationPolicy: .regular, executablePath: nil,
            windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
            windowOrder: [1001, 1002], isHidden: false))
        tracker.setFrontmostPIDForTesting(-41000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002])
        defer { gate.release.signal(); tracker.stop() }
        tracker.handleFocusedWindowChanged(pid: -41000)
        await waitForFocus { gate.entered.withLock { $0 } && tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status == .active }
        let pending = tracker.pendingInventoryWorkForTesting
        desktop.state.withLock { $0.focused = 1002 }
        gate.release.signal()
        for task in pending { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1002")]?.status, .active)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status, .inactive)
    }

    func testFocusBetweenMonitorsUpdatesButtonsBeforeAnInFlightInventoryReadCompletes() async throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.windows[1001]?.bounds = CGRect(x: 40, y: 30, width: 800, height: 700)
            $0.windows[1002]?.bounds = CGRect(x: 1040, y: 30, width: 800, height: 700)
            $0.windows[2001]?.bounds = CGRect(x: 80, y: 30, width: 800, height: 700)
        }
        let table = WindowDisplayAttribution.Table(displays: [
            .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "right", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        ], primaryUUID: "left")
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 1002, 2001], onScreenWindowIDs: [1001, 1002, 2001],
            windowIDsByPID: [-41000: [1001, 1002], -42000: [2001]],
            alphaByWindowID: [1001: 1, 1002: 1, 2001: 1])
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 1002, 2001] }, displayTableProvider: { table })
        for pid: pid_t in [-41000, -42000] {
            let records = desktop.state.withLock { $0.windows.values.filter { $0.pid == pid }.sorted { $0.cgWindowID! < $1.cgWindowID! } }
            let entries = records.map { record in
                WindowEntry(cgWindowID: record.cgWindowID!, token: record.groupID, title: record.title, bounds: record.bounds,
                            isMinimized: false, isFocused: record.cgWindowID == 1001 || record.cgWindowID == 2001,
                            everSeenVisible: true, displayUUID: record.cgWindowID == 1002 ? "right" : "left")
            }
            tracker.installFixtureForTesting(AppEntry(pid: pid, bundleIdentifier: records[0].bundleIdentifier,
                appName: pid == -41000 ? "Chrome" : "Codex", activationPolicy: .regular, executablePath: nil,
                windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
                windowOrder: entries.map(\.cgWindowID), isHidden: false, processGeneration: .init(timeval(tv_sec: 1, tv_usec: 0))))
        }
        tracker.setFrontmostPIDForTesting(-41000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002, 2001])
        let runtime = AppRuntime(tracker: ControlledInventoryLifecycle(tracker))
        let spaces = TaskbarSpaceStore(read: { requests in
            .init(layouts: ["left": .init(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1),
                            "right": .init(orderedSpaceIDs: [2], fullscreenSpaceIDs: [], currentSpaceID: 2)],
                  memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([$0.identity.windowID == 1002 ? 2 : 1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "ProperWM.FocusLatency.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 2,
            identifiedDisplayUUIDs: ["left", "right"], attributionTable: table))
        let views = [TaskbarView(frame: CGRect(x: 0, y: 0, width: 1000, height: 32)),
                     TaskbarView(frame: CGRect(x: 0, y: 0, width: 1000, height: 32))]
        let presenters = zip(views, ["left", "right"]).map { view, display in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering, topology: topology, spaces: spaces,
                displayUUID: display, backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        }
        runtime.start()
        spaces.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { spaces.stop(); runtime.stop(); withExtendedLifetime(presenters) {} }
        func active(_ index: Int, _ window: String) -> Bool {
            views[index].taskbarContent.buttonViews["window:" + window]?.isActiveWindow == true
        }
        func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(1)
            while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(predicate(), file: file, line: line)
        }
        await wait { active(0, "tabgrp-editor-a") }
        tracker.setFrontmostPIDForTesting(-42000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002, 2001])
        await wait { active(0, "tabgrp-browser-c") && !active(0, "tabgrp-editor-a") }
        tracker.setFrontmostPIDForTesting(-41000)
        desktop.state.withLock { $0.focused = 1002 }
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        await wait { active(1, "tabgrp-editor-b") && !active(0, "tabgrp-browser-c") }
        let gate = FocusInventoryGate()
        desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        await wait { gate.state.withLock { $0.entered.contains(0) } }
        let oldRead = tracker.pendingInventoryWorkForTesting
        defer { gate.gates.forEach { $0.signal() } }
        desktop.state.withLock { $0.focused = 1001 }
        tracker.handleFocusedWindowChanged(pid: -41000)
        await wait { active(0, "tabgrp-editor-a") && !active(1, "tabgrp-editor-b") }
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: -41000))
        XCTAssertEqual(gate.state.withLock { $0.inventoryReads }, 1)
        gate.gates[0].signal()
        for task in oldRead { await task.value }
        await wait { gate.state.withLock { $0.entered.contains(1) } }
        await wait { active(0, "tabgrp-editor-a") && !active(1, "tabgrp-editor-b") }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status, .active)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1002")]?.status, .inactive)
        gate.gates[1].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertTrue(active(0, "tabgrp-editor-a"))
        XCTAssertFalse(active(1, "tabgrp-editor-b"))
        XCTAssertFalse(active(0, "tabgrp-browser-c"))
        XCTAssertEqual(gate.state.withLock { $0.inventoryReads }, 2)
        XCTAssertTrue(views.allSatisfy { $0.window == nil })
    }

    func testProcessChurnReleasesGenerationsIncludingUntrackedAndFinderProcesses() {
        let tracker = tracker(reader: LifecycleReader())
        defer { tracker.stop() }
        tracker.setFrontmostPIDForTesting(-1)
        for pid in Int32(40_000)..<41_000 {
            tracker.installFixtureForTesting(.init(pid: pid, bundleIdentifier: "test.app", appName: "App",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            tracker.terminateForTesting(pid: pid)
            tracker.terminateForTesting(pid: pid + 10_000)
        }
        tracker.installFixtureForTesting(.init(pid: 42, bundleIdentifier: "com.apple.finder", appName: "Finder",
            activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
        tracker.terminateForTesting(pid: 42)
        XCTAssertEqual(tracker.mutationGenerationCountForTesting, 0)
        XCTAssertTrue(tracker.diagnosticApps().isEmpty)
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
    }

    func testTerminatedProcessReadCannotConsumeReplacementProcessRead() async {
        let reader = LifecycleReader()
        let process = LifecycleProcess()
        let tracker = tracker(reader: reader, process: process)
        defer { tracker.stop() }
        let pid = NSRunningApplication.current.processIdentifier
        func entry(_ title: String) -> AppEntry {
            .init(pid: pid, bundleIdentifier: "test.app", appName: "App", activationPolicy: .regular,
                executablePath: nil, windowsByID: [77: .init(cgWindowID: 77, token: title, title: title,
                    bounds: CGRect(x: 40, y: 40, width: 640, height: 480), isMinimized: false, isFocused: false)],
                windowOrder: [77], isHidden: false)
        }
        tracker.installFixtureForTesting(entry("Original"))
        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)
        await waitForRead(reader)
        let old = tracker.pendingInventoryWorkForTesting
        tracker.terminateForTesting(pid: pid)
        XCTAssertEqual(tracker.mutationGenerationCountForTesting, 0)
        process.generation.withLock { $0 += 1 }
        tracker.installFixtureForTesting(entry("Replacement"))
        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        await waitForRead(reader, count: 2)
        reader.gates[0].signal()
        for task in old { await task.value }
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pid))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[77]?.title, "Replacement")
        reader.gates[1].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 1"])
        XCTAssertEqual(tracker.mutationGenerationCountForTesting, 1)
    }

    func testStandaloneNonmodalSettingsDialogsAreShownWithoutAdmittingSheetsOrUtilityPanels() async {
        let cases: [(modal: Bool?, topLevel: Bool, subrole: String, count: Int)] = [
            (false, true, kAXDialogSubrole as String, 1),
            (true, true, kAXDialogSubrole as String, 0),
            (nil, true, kAXDialogSubrole as String, 0),
            (false, false, kAXDialogSubrole as String, 0),
            (false, true, kAXFloatingWindowSubrole as String, 0)
        ]
        for sample in cases {
            let desktop = BehaviorDesktop()
            desktop.state.withLock {
                $0.windows = $0.windows.filter { $0.key == 1001 }
                $0.windows[1001]?.title = "Profiles"
                $0.subroles[1001] = sample.subrole
                $0.modalWindows[1001] = sample.modal
                if sample.topLevel { $0.topLevelWindows.insert(1001) }
            }
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001], onScreenWindowIDs: [1001],
                windowIDsByPID: [-41000: [1001]], alphaByWindowID: [1001: 1])
            let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001] })
            tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.SettingsApp", appName: "SettingsApp",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            defer { tracker.stop() }
            tracker.scheduleFrontmostPollForTesting(pid: -41000)
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            let windows = StripItem.openWindows(from: tracker.snapshot)
            XCTAssertEqual(windows.count, sample.count, "modal=\(String(describing: sample.modal)) topLevel=\(sample.topLevel) subrole=\(sample.subrole)")
            if sample.count == 1 { XCTAssertEqual(windows.first?.title, "Profiles") }
        }
    }

    func testCustomWindowIsDiscoveredThroughEachAdmissionPathWithAnEmptyList() async throws {
        for source in ["seed", "scan", "launchRetry"] {
            for listed in [false, true] {
                let pid = ProcessInfo.processInfo.processIdentifier
                let desktop = BehaviorDesktop(browserPID: pid)
                desktop.state.withLock {
                    $0.focused = 2001
                    $0.windows[2001]?.title = "Scene"
                    $0.subroles[2001] = kAXUnknownSubrole as String
                    $0.modalWindows[2001] = false
                    $0.topLevelWindows.insert(2001)
                    $0.enumeratedWindows[pid] = listed ? [2001] : []
                }
                let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [2001], onScreenWindowIDs: [2001],
                    windowIDsByPID: [pid: [2001]], alphaByWindowID: [2001: 1], parentWindowIDs: [2001: 0])
                let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                    cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [2001] })
                defer { tracker.stop() }
                let app = FamilyRunningApplication(pid: pid, identifier: "test.Renderer", policy: .regular,
                    path: "/Applications/Renderer.app")
                tracker.runAdmissionForTesting(source: source, app: app, application: app.eligibility)
                await drainInventory(tracker)
                let window = try XCTUnwrap(tracker.snapshot.windows.values.first, "\(source), listed=\(listed)")
                XCTAssertEqual(tracker.snapshot.windows.count, 1)
                XCTAssertEqual(window.cgWindowID, 2001)
                XCTAssertEqual(window.pid, pid)
                XCTAssertEqual(window.title, "Scene")
                if source == "seed", !listed {
                    desktop.state.withLock { $0.generationsByPID[pid] = window.processGeneration }
                    let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
                    func execute(_ kind: PlatformActionRequest.ActionKind, minimized: Bool = false) -> Bool {
                        executor.execute(.init(kind: kind, windowID: window.id), snapshot: tracker.snapshot,
                            forcedMinimizedPrior: minimized, cancellation: OperationCancellation(), onHandoffActivePrediction: nil)
                    }
                    XCTAssertTrue(execute(.minimizeWindow))
                    XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.status }, .minimized)
                    XCTAssertTrue(execute(.activateWindow, minimized: true))
                    XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.status }, .active)
                    XCTAssertTrue(execute(.closeWindow))
                    XCTAssertNil(desktop.state.withLock { $0.windows[2001] })
                    XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.status }, .inactive)
                    XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.status }, .inactive)
                }
            }
        }
    }

    func testCustomWindowAdmissionRequiresIndependentNativeAndSemanticEvidence() async {
        for rejection in ["child", "utility", "modal", "unreadModal", "nested", "unreadRoot",
                          "foreignCG", "offLayer", "transparent", "untitledInactive", "tooSmall"] {
            let desktop = BehaviorDesktop()
            desktop.state.withLock {
                $0.windows = $0.windows.filter { $0.key == 1001 }
                $0.subroles[1001] = rejection == "utility" ? kAXFloatingWindowSubrole as String : kAXUnknownSubrole as String
                $0.modalWindows[1001] = rejection == "unreadModal" ? nil : rejection == "modal"
                if rejection != "nested" { $0.topLevelWindows.insert(1001) }
                if rejection == "untitledInactive" { $0.windows[1001]?.title = ""; $0.focused = nil }
                if rejection == "tooSmall" { $0.windows[1001]?.bounds = CGRect(x: 40, y: 40, width: 20, height: 20) }
            }
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001], onScreenWindowIDs: [1001],
                windowIDsByPID: rejection == "offLayer" ? [:] : [rejection == "foreignCG" ? -42000 : -41000: [1001]],
                alphaByWindowID: [1001: rejection == "transparent" ? 0 : 1],
                parentWindowIDs: rejection == "unreadRoot" ? [:] : [1001: rejection == "child" ? 2000 : 0])
            let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001] })
            defer { tracker.stop() }
            tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Renderer", appName: "Renderer",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            tracker.scheduleFrontmostPollForTesting(pid: -41000)
            await drainInventory(tracker)
            XCTAssertTrue(tracker.snapshot.windows.isEmpty, rejection)
        }
    }

    func testUntitledCustomWindowNeedsExactWindowFocus() async {
        for focused in [false, true] {
            let desktop = BehaviorDesktop()
            desktop.state.withLock {
                $0.windows = $0.windows.filter { $0.key == 1001 }
                $0.windows[1001]?.title = ""
                $0.subroles[1001] = kAXUnknownSubrole as String
                $0.modalWindows[1001] = false
                $0.topLevelWindows.insert(1001)
                $0.focused = focused ? 1001 : nil
            }
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001], onScreenWindowIDs: [1001],
                windowIDsByPID: [-41000: [1001]], alphaByWindowID: [1001: 1], parentWindowIDs: [1001: 0])
            let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001] })
            defer { tracker.stop() }
            tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Renderer", appName: "Renderer",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            tracker.scheduleFrontmostPollForTesting(pid: -41000)
            await drainInventory(tracker)
            XCTAssertEqual(tracker.snapshot.windows.count, focused ? 1 : 0)
        }
    }

    func testChangingFocusBetweenOverlappingCustomRootsPreservesIndependentSeats() async throws {
        for listed in [false, true] {
            let desktop = BehaviorDesktop()
            desktop.state.withLock {
                if !listed { $0.enumeratedWindows[-41000] = [] }
                for id: CGWindowID in [1001, 1002] {
                    $0.windows[id]?.title = ""
                    $0.subroles[id] = kAXUnknownSubrole as String
                    $0.modalWindows[id] = false
                    $0.topLevelWindows.insert(id)
                }
            }
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 1002], onScreenWindowIDs: [1001, 1002],
                windowIDsByPID: [-41000: [1001, 1002]], alphaByWindowID: [1001: 1, 1002: 1],
                parentWindowIDs: [1001: 0, 1002: 0])
            let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 1002] })
            defer { tracker.stop() }
            tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Renderer", appName: "Renderer",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            tracker.scheduleFrontmostPollForTesting(pid: -41000)
            await drainInventory(tracker)
            let originalID = try XCTUnwrap(tracker.snapshot.windows.values.first?.id)
            for focused: CGWindowID in [1002, 1001, 1002] {
                desktop.state.withLock { $0.focused = focused }
                tracker.scheduleFrontmostPollForTesting(pid: -41000)
                await drainInventory(tracker)
                XCTAssertEqual(Set(tracker.snapshot.windows.values.compactMap(\.cgWindowID)), [1001, 1002])
                XCTAssertEqual(tracker.snapshot.windows[originalID]?.cgWindowID, 1001)
                XCTAssertTrue(tracker.fixtureAppForTesting(pid: -41000)?.windowsByID.values.allSatisfy { $0.formerCgIDs.isEmpty } == true)
            }
        }
    }

    func testConfirmedNativeChildRetiresWithoutTreatingMissingParentDataAsAbsence() async {
        for outcome in ["child", "unreadChild", "unknownParent", "failedCapture"] {
            let pid = ProcessInfo.processInfo.processIdentifier
            let desktop = BehaviorDesktop(browserPID: pid)
            desktop.state.withLock {
                $0.focused = 2001
                $0.enumeratedWindows[pid] = [2001]
                $0.subroles[2001] = kAXUnknownSubrole as String
                $0.modalWindows[2001] = false
                $0.topLevelWindows.insert(2001)
            }
            let original = AppTrackerCGWindowSnapshot(allWindowIDs: [2001], onScreenWindowIDs: [2001],
                windowIDsByPID: [pid: [2001]], alphaByWindowID: [2001: 1], parentWindowIDs: [2001: 0])
            let current = Mutex(original)
            let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                cgSnapshotProvider: { current.withLock { $0 } }, onScreenWindowIDsProvider: { [2001] })
            defer { tracker.stop() }
            tracker.installFixtureForTesting(AppEntry(pid: pid, bundleIdentifier: "test.Renderer", appName: "Renderer",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            tracker.scheduleFrontmostPollForTesting(pid: pid)
            await drainInventory(tracker)
            XCTAssertEqual(tracker.snapshot.windows.count, 1)
            XCTAssertEqual(AXElementCache.shared.containsForTesting(pid: pid, cgWindowID: 2001), AXElementCache.isEnabled)
            current.withLock {
                $0 = outcome == "failedCapture" ? .failed : AppTrackerCGWindowSnapshot(
                    allWindowIDs: [2001], onScreenWindowIDs: [2001], windowIDsByPID: [pid: [2001]],
                    alphaByWindowID: [2001: 1], parentWindowIDs: outcome == "unknownParent" ? [:] : [2001: 2000])
            }
            if outcome == "unreadChild" { desktop.state.withLock { $0.unreadInventories.insert(pid) } }
            tracker.scheduleFrontmostPollForTesting(pid: pid)
            await drainInventory(tracker)
            let detached = outcome == "child" || outcome == "unreadChild"
            XCTAssertEqual(tracker.snapshot.windows.count, detached ? 0 : 1, outcome)
            XCTAssertEqual(AXElementCache.shared.containsForTesting(pid: pid, cgWindowID: 2001), !detached && AXElementCache.isEnabled, outcome)
            if detached {
                current.withLock { $0 = original }
                desktop.state.withLock { $0.unreadInventories.remove(pid) }
                tracker.scheduleFrontmostPollForTesting(pid: pid)
                await drainInventory(tracker)
                XCTAssertEqual(tracker.snapshot.windows.count, 1, "A detached root must return without a destroy tombstone")
            }
        }
    }

    func testKnownUntitledCustomRootRefreshesMinimizedStateAfterFocusIsLost() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.windows[1001]?.title = ""
            $0.enumeratedWindows[-41000] = [1001]
            $0.subroles[1001] = kAXUnknownSubrole as String
            $0.modalWindows[1001] = false
            $0.topLevelWindows.insert(1001)
        }
        let current = Mutex(AppTrackerCGWindowSnapshot(allWindowIDs: [1001], onScreenWindowIDs: [1001],
            windowIDsByPID: [-41000: [1001]], alphaByWindowID: [1001: 1], parentWindowIDs: [1001: 0]))
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
            cgSnapshotProvider: { current.withLock { $0 } }, onScreenWindowIDsProvider: { [] })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Renderer", appName: "Renderer",
            activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        await drainInventory(tracker)
        XCTAssertEqual(tracker.snapshot.windows.count, 1)
        desktop.state.withLock { $0.focused = nil; $0.windows[1001]?.status = .minimized }
        current.withLock {
            $0 = AppTrackerCGWindowSnapshot(allWindowIDs: [1001], onScreenWindowIDs: [],
                windowIDsByPID: [-41000: [1001]], alphaByWindowID: [1001: 1], parentWindowIDs: [1001: 0])
        }
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        await drainInventory(tracker)
        XCTAssertEqual(tracker.snapshot.windows.values.first?.status, .minimized)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: -41000)?.windowsByID[1001]?.isMinimized, true)
    }

    func testFreshConfirmedFocusIsAppliedBeforeCustomWindowEligibility() async {
        let desktop = BehaviorDesktop()
        let gate = CustomFocusGate()
        desktop.state.withLock {
            for id: CGWindowID in [1001, 1002] {
                $0.windows[id]?.title = ""
                $0.subroles[id] = kAXUnknownSubrole as String
                $0.modalWindows[id] = false
                $0.topLevelWindows.insert(id)
            }
            $0.beforeRead = { gate.read($0) }
        }
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 1002], onScreenWindowIDs: [1001, 1002],
            windowIDsByPID: [-41000: [1001, 1002]], alphaByWindowID: [1001: 1, 1002: 1],
            parentWindowIDs: [1001: 0, 1002: 0])
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 1002] })
        defer { gate.first.signal(); gate.second.signal(); tracker.stop() }
        let entries = [UInt32(1001)].map { id in
            WindowEntry(cgWindowID: id, token: "tabgrp-\(id)", title: "",
                bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050),
                isMinimized: false, isFocused: id == 1001, everSeenVisible: true)
        }
        tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Renderer", appName: "Renderer",
            activationPolicy: .regular, executablePath: nil,
            windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
            windowOrder: [1001], isHidden: false))
        tracker.setFrontmostPIDForTesting(-41000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002])
        tracker.scheduleEventReadForTesting(pid: -41000, source: .frontmostPoll)
        await waitForFocus { gate.state.withLock { $0.heldFirst } }
        let old = tracker.pendingInventoryWorkForTesting
        desktop.state.withLock { $0.focused = 1002 }
        tracker.handleFocusedWindowChanged(pid: -41000)
        await waitForFocus { tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status == .inactive }
        XCTAssertNil(tracker.snapshot.windows[WindowID(rawValue: "cgw-1002")])
        gate.first.signal()
        for task in old { await task.value }
        await waitForFocus { gate.state.withLock { $0.heldSecond } }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1002")]?.status, .active)
        XCTAssertEqual(tracker.snapshot.windows.count, 2)
    }

    private func familyFocusTracker(_ desktop: FamilyFocusAccessibility, process: FamilyFocusProcess = FamilyFocusProcess()) async -> AppTracker {
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 2001, 3000], onScreenWindowIDs: [1001, 2001, 3000],
            windowIDsByPID: [-41000: [1001], -42000: [2001], -44000: [3000]], alphaByWindowID: [:])
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: process,
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 2001, 3000] })
        tracker.setFrontmostPIDForTesting(-41000)
        for app in FamilyRunningApplication.family {
            tracker.runAdmissionForTesting(source: "seed", app: app, application: app.eligibility)
            await drainInventory(tracker)
        }
        return tracker
    }

    private func drainInventory(_ tracker: AppTracker) async {
        while !tracker.pendingInventoryWorkForTesting.isEmpty {
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
        }
    }

    private func assertFamilyActions(_ tracker: AppTracker, active: CGWindowID?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tracker.snapshot.windows.count, 3, file: file, line: line)
        let planner = LifecycleActionPlanner(isAppFrontmost: { $0 == -41000 })
        for window in tracker.snapshot.windows.values {
            XCTAssertEqual(window.status, window.cgWindowID == active ? .active : .inactive, file: file, line: line)
            XCTAssertEqual(planner.plan(intent: .toggle(window.id), snapshot: tracker.snapshot).kind,
                           window.cgWindowID == active ? .minimizeWindow : .activateWindow, file: file, line: line)
        }
    }

    func testFrontmostHostDoesNotPromoteFreshLocalFocusFromMultipleHelpers() async {
        let desktop = FamilyFocusAccessibility()
        let tracker = await familyFocusTracker(desktop)
        defer { tracker.stop() }
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        await drainInventory(tracker)
        assertFamilyActions(tracker, active: 1001)
        XCTAssertTrue(desktop.desktop.state.withLock { $0.writes.isEmpty })
    }

    func testUnreadSystemFocusCannotMinimizeAnyCachedHelperWindow() async {
        let desktop = FamilyFocusAccessibility()
        let tracker = await familyFocusTracker(desktop)
        defer { tracker.stop() }
        desktop.state.withLock { $0.systemError = .cannotComplete }
        tracker.handleFocusedWindowChanged(pid: -42000)
        tracker.handleFocusedWindowChanged(pid: -44000)
        await drainInventory(tracker)
        assertFamilyActions(tracker, active: nil)
    }

    func testSystemSelectedHelperCanMinimizeWhileOtherFamilyWindowsActivate() async {
        let desktop = FamilyFocusAccessibility()
        desktop.state.withLock { $0.focused = 3000 }
        let tracker = await familyFocusTracker(desktop)
        defer { tracker.stop() }
        tracker.handleFocusedWindowChanged(pid: -44000)
        await drainInventory(tracker)
        assertFamilyActions(tracker, active: 3000)
    }

    func testExcludedAndSelfApplicationActivationClearsThePreviousActiveHighlight() async {
        for excluded in [FamilyRunningApplication(pid: -45000, identifier: DockWindowEligibilityPolicy.selfBundleIdentifier,
                                                  policy: .regular, path: "/Applications/ProperWM.app"),
                         FamilyRunningApplication(pid: -46000, identifier: "test.Excluded", policy: .prohibited,
                                                  path: "/Applications/Excluded.app")] {
            let tracker = focusTracker(FocusLifecycleReader(blockFirst: false), focused: 77)
            tracker.runAdmissionForTesting(source: "seed", app: excluded, application: excluded.eligibility)
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            tracker.start()
            defer { tracker.stop() }
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            tracker.setFrontmostPIDForTesting(42)
            tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77, 88])
            XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.status, .active)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: excluded])
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.status, .inactive)
        }
    }

    func testFamilySystemFocusReadCoalescesABurstAndSnapshotBuildingDoesNotReadAX() async {
        let desktop = FamilyFocusAccessibility()
        let tracker = await familyFocusTracker(desktop)
        defer { desktop.gate.signal(); tracker.stop() }
        let originalReads = desktop.state.withLock { $0.systemReads }
        for _ in 0..<20 { tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 2001, 3000]) }
        XCTAssertEqual(desktop.state.withLock { $0.systemReads }, originalReads)
        desktop.state.withLock { $0.blockAtRead = originalReads + 1 }
        tracker.handleFocusedWindowChanged(pid: -44000)
        await waitForFocus { desktop.state.withLock { $0.systemReads == originalReads + 1 } }
        desktop.state.withLock { $0.focused = 3000 }
        for _ in 0..<20 { tracker.handleFocusedWindowChanged(pid: -44000) }
        desktop.gate.signal()
        await drainInventory(tracker)
        assertFamilyActions(tracker, active: 3000)
        XCTAssertLessThanOrEqual(desktop.state.withLock { $0.systemReads } - originalReads, 4)
        XCTAssertFalse(desktop.state.withLock { $0.usedMainThread })
    }

    func testStableHelperFocusPollingDoesNotRepublishOrClearTheActiveSnapshot() async {
        let desktop = FamilyFocusAccessibility()
        desktop.state.withLock { $0.focused = 3000 }
        let tracker = await familyFocusTracker(desktop)
        defer { tracker.stop() }
        assertFamilyActions(tracker, active: 3000)
        var publications = 0
        let subscription = tracker.$snapshot.sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<5 {
            tracker.scheduleFrontmostPollForTesting(pid: -41000)
            await drainInventory(tracker)
            assertFamilyActions(tracker, active: 3000)
        }
        XCTAssertEqual(publications, 1)
    }

    func testLateFamilySystemFocusCannotPublishForAReplacedHelperOrHost() async {
        for replacedPID: pid_t in [-41000, -44000] {
            let desktop = FamilyFocusAccessibility()
            let process = FamilyFocusProcess()
            let tracker = await familyFocusTracker(desktop, process: process)
            defer { desktop.gate.signal(); tracker.stop() }
            let nextRead = desktop.state.withLock { $0.systemReads + 1 }
            desktop.state.withLock { $0.focused = 3000; $0.blockAtRead = nextRead }
            tracker.handleFocusedWindowChanged(pid: -44000)
            await waitForFocus { desktop.state.withLock { $0.systemReads == nextRead } }
            process.generations.withLock { $0[replacedPID] = 11 }
            desktop.gate.signal()
            await drainInventory(tracker)
            XCTAssertFalse(tracker.snapshot.windows.values.contains { $0.status == .active })
            XCTAssertNil(tracker.snapshot.windows[WindowID(rawValue: "cgw-3000")])
        }
    }

    func testLateFamilySystemFocusCannotRestoreHighlightAfterAFrontmostChangeOrStop() async {
        for stop in [false, true] {
            let desktop = FamilyFocusAccessibility()
            let tracker = await familyFocusTracker(desktop)
            defer { desktop.gate.signal(); tracker.stop() }
            let nextRead = desktop.state.withLock { $0.systemReads + 1 }
            desktop.state.withLock { $0.focused = 3000; $0.blockAtRead = nextRead }
            tracker.handleFocusedWindowChanged(pid: -44000)
            await waitForFocus { desktop.state.withLock { $0.systemReads == nextRead } }
            let pending = tracker.pendingInventoryWorkForTesting
            if stop { tracker.stop() }
            else {
                tracker.setFrontmostPIDForTesting(-45000)
                tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 2001, 3000])
            }
            desktop.gate.signal()
            for task in pending { await task.value }
            XCTAssertFalse(tracker.snapshot.windows.values.contains { $0.status == .active })
            if stop { XCTAssertTrue(tracker.snapshot.windows.isEmpty) }
        }
    }

    func testSystemFocusConfirmationCannotOutliveASeatMutation() async throws {
        for delayed in [false, true] {
            let desktop = FamilyFocusAccessibility()
            desktop.state.withLock { $0.focused = 3000 }
            let tracker = await familyFocusTracker(desktop)
            defer { desktop.gate.signal(); tracker.stop() }
            if delayed {
                let nextRead = desktop.state.withLock { $0.systemReads + 1 }
                desktop.state.withLock { $0.blockAtRead = nextRead }
                tracker.handleFocusedWindowChanged(pid: -44000)
                await waitForFocus { desktop.state.withLock { $0.systemReads == nextRead } }
            }
            var replacement = try XCTUnwrap(tracker.fixtureAppForTesting(pid: -44000))
            replacement.windowsByID[3000] = WindowEntry(cgWindowID: 3000, token: "replacement-native-seat", title: "Replacement",
                bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050), isMinimized: false, isFocused: true)
            tracker.installFixtureForTesting(replacement)
            tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 2001, 3000])
            desktop.gate.signal()
            await drainInventory(tracker)
            assertFamilyActions(tracker, active: nil)
        }
    }

    func testSystemFocusReadResolvesAControlToItsNativeHelperWindowWithoutInventory() {
        let desktop = FamilyFocusAccessibility()
        desktop.state.withLock { $0.focused = 3000; $0.focusedControl = true }
        let result = AXWindowReader(accessibility: desktop).systemFocusedWindowRead(messagingTimeout: 0.05,
            cancellation: OperationCancellation())
        XCTAssertEqual(result.result, .window(pid: -44000, windowID: 3000))
        XCTAssertEqual(desktop.state.withLock { $0.attributes }, [kAXFocusedUIElementAttribute as String,
            kAXRoleAttribute as String, kAXWindowAttribute as String, kAXFocusedUIElementAttribute as String])
    }

    func testSystemFocusReadDoesNotChangeTheClientGlobalMessagingTimeout() {
        let desktop = FamilyFocusAccessibility()
        let result = AXWindowReader(accessibility: desktop).systemFocusedWindowRead(messagingTimeout: 0.05,
            cancellation: OperationCancellation())
        XCTAssertEqual(result.result, .window(pid: -41000, windowID: 1001))
        XCTAssertEqual(desktop.state.withLock { $0.systemTimeoutWrites }, 0)
    }

    func testSystemFocusReadRejectsChangedFocusMismatchedOwnersAndCancellation() {
        for mode in ["changed", "owner", "cancel"] {
            let desktop = FamilyFocusAccessibility()
            let cancellation = OperationCancellation()
            desktop.state.withLock {
                $0.focused = 3000
                $0.focusedControl = true
                if mode == "owner" { $0.controlOwner = -42000 }
                $0.beforeRead = { [weak desktop] attribute in
                    guard attribute == kAXRoleAttribute as String else { return }
                    if mode == "changed" { desktop?.state.withLock { $0.focused = 1001 } }
                    if mode == "cancel" { cancellation.cancel() }
                }
            }
            let result = AXWindowReader(accessibility: desktop).systemFocusedWindowRead(messagingTimeout: 0.05,
                cancellation: cancellation)
            XCTAssertEqual(result.result, .unread(mode == "cancel" ? .cannotComplete : .invalidUIElement), mode)
            XCTAssertFalse(desktop.state.withLock { $0.attributes.contains(kAXWindowsAttribute as String) })
        }
    }

    private var embeddedApplication: AppTrackerWindowEligibility.Application {
        .init(bundleIdentifier: "test.Host.helper", appName: "Helper", activationPolicy: .accessory,
              executablePath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app/Contents/MacOS/Helper",
              bundleURL: URL(fileURLWithPath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app"))
    }

    func testSeedAndScanRequestOneOwnershipBatchAwayFromTheMainThread() async {
        for source in ["seed", "scan"] {
            let reader = AdmissionWindowReader()
            let process = OwnedApplicationProcess()
            let tracker = ownedTracker(reader: reader, process: process)
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source, application: embeddedApplication)
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            XCTAssertEqual(tracker.snapshot.windows.count, 1, source)
            XCTAssertEqual(process.batchLookups.withLock { $0 }, 1, source)
            XCTAssertEqual(process.lookups.withLock { $0 }, 1, source)
            XCTAssertFalse(process.usedMainThread.withLock { $0 }, source)
        }
    }

    private func ownedTracker(reader: any AppTrackerWindowReading, process: OwnedApplicationProcess) -> AppTracker {
        let pid = NSRunningApplication.current.processIdentifier
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [77], onScreenWindowIDs: [77],
            windowIDsByPID: [pid: [77]], alphaByWindowID: [77: 1])
        return AppTracker(reader: reader, processProvider: process,
                          cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [77] })
    }

    func testLateAdmissionCannotReplaceTheBindingOfAnAlreadyAdmittedHelper() async {
        let reader = LifecycleReader()
        let process = OwnedApplicationProcess()
        let tracker = ownedTracker(reader: reader, process: process)
        defer { reader.gates.forEach { $0.signal() }; tracker.stop() }
        process.parentGeneration.withLock { $0 = 9 }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        await waitForRead(reader)
        process.parentGeneration.withLock { $0 = 10 }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        await waitForRead(reader, count: 2)
        reader.gates[1].signal()
        await waitForFocus { tracker.snapshot.windows.count == 1 }
        XCTAssertEqual(tracker.snapshot.windows.values.first?.title, "Read 1")
        reader.gates[0].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77])
        XCTAssertEqual(tracker.snapshot.windows.count, 1)
        XCTAssertEqual(tracker.snapshot.windows.values.first?.owningApplication?.generation,
                       ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
    }

    func testFrontmostHostPollingRefreshesItsOwnedHelper() async {
        let reader = AdmissionWindowReader()
        let process = OwnedApplicationProcess()
        let tracker = ownedTracker(reader: reader, process: process)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        tracker.setFrontmostPIDForTesting(-43000)
        reader.state.withLock { $0.focused = true }
        tracker.scheduleFrontmostPollForTesting(pid: -43000)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.values.first?.status, .active)
        XCTAssertEqual(reader.state.withLock { $0.reads }, 2)
        XCTAssertEqual(process.lookups.withLock { $0 }, 1)
    }

    func testMainApplicationTerminationRetiresItsHelperInventory() async {
        let reader = AdmissionWindowReader()
        let process = OwnedApplicationProcess()
        let tracker = ownedTracker(reader: reader, process: process)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.count, 1)
        process.parentAlive.withLock { $0 = false }
        tracker.handleAppTerminated(pid: -43000)
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        XCTAssertTrue(tracker.diagnosticApps().isEmpty)
    }

    func testVerifiedEmbeddedHelperIsAdmittedWithoutChangingItsWindowOwner() async {
        let pid = NSRunningApplication.current.processIdentifier
        for source in ["seed", "scan", "launchRetry"] {
            let reader = AdmissionWindowReader()
            let process = OwnedApplicationProcess()
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [77], onScreenWindowIDs: [77],
                windowIDsByPID: [pid: [77]], alphaByWindowID: [77: 1])
            let tracker = AppTracker(reader: reader, processProvider: process,
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [77] })
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source, application: .init(
                bundleIdentifier: "test.Host.helper", appName: "Helper", activationPolicy: .accessory,
                executablePath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app/Contents/MacOS/Helper",
                bundleURL: URL(fileURLWithPath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app")))
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).count, 1, source)
            XCTAssertEqual(tracker.snapshot.windows.values.first?.pid, pid, source)
            XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).first?.bundleIdentifier, "test.Host", source)
            XCTAssertEqual(tracker.snapshot.windows.values.first?.bundleIdentifier, "test.Host.helper", source)
            XCTAssertFalse(process.usedMainThread.withLock { $0 }, source)
            XCTAssertEqual(process.lookups.withLock { $0 }, 1, source)
        }
    }

    func testAccessoryDashboardIsAdmittedBySeedScanAndLaunchRetry() async {
        for source in ["seed", "scan", "launchRetry"] {
            let reader = AdmissionWindowReader()
            let tracker = admissionTracker(reader: reader)
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source, application: .init(
                bundleIdentifier: "eu.exelban.Stats", appName: "Stats", activationPolicy: .accessory,
                executablePath: "/Applications/Stats.app/Contents/MacOS/Stats",
                bundleURL: URL(fileURLWithPath: "/Applications/Stats.app")))
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            let windows = StripItem.openWindows(from: tracker.snapshot)
            XCTAssertEqual(windows.map(\.title), ["Dashboard"], source)
            XCTAssertEqual(windows.map(\.bundleIdentifier), ["eu.exelban.Stats"], source)
            XCTAssertFalse(reader.state.withLock { $0.usedMainThread }, source)
        }
    }

    func testAccessoryWindowFiltersStillRejectUtilityAndInvisibleSurfaces() async {
        for source in ["seed", "scan", "launchRetry"] {
            for kind in AdmissionWindowReader.RejectedKind.allCases {
                let reader = AdmissionWindowReader(rejected: kind)
                let tracker = admissionTracker(reader: reader)
                defer { tracker.stop() }
                tracker.runAdmissionForTesting(source: source, application: .init(
                    bundleIdentifier: "test.menubar", appName: "MenuBar", activationPolicy: .accessory,
                    executablePath: nil, bundleURL: URL(fileURLWithPath: "/Applications/MenuBar.app")))
                for task in tracker.pendingInventoryWorkForTesting { await task.value }
                XCTAssertTrue(StripItem.openWindows(from: tracker.snapshot).isEmpty, "\(source): \(kind)")
                XCTAssertTrue(tracker.diagnosticApps().isEmpty, "\(source): \(kind)")
            }
        }
    }

    func testAccessoryWindowCanReopenFromAnEventWithoutPeriodicAdmission() async {
        let reader = AdmissionWindowReader()
        let tracker = admissionTracker(reader: reader)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed", application: .init(
            bundleIdentifier: "eu.exelban.Stats", appName: "Stats", activationPolicy: .accessory,
            executablePath: nil, bundleURL: URL(fileURLWithPath: "/Applications/Stats.app")))
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        let pid = NSRunningApplication.current.processIdentifier
        XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).count, 1)
        reader.state.withLock { $0.windowID = nil }
        tracker.destroyForTesting(pid: pid, cgWindowID: 77)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertTrue(StripItem.openWindows(from: tracker.snapshot).isEmpty)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid))
        reader.state.withLock { $0.windowID = 78 }
        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).map(\.title), ["Dashboard"])
        XCTAssertEqual(tracker.snapshot.windows.values.compactMap(\.cgWindowID), [78])
    }

    func testProhibitedSelfAndEmbeddedHelpersCannotBeAdmitted() async {
        let applications: [AppTrackerWindowEligibility.Application] = [
            .init(bundleIdentifier: "test.background", appName: "Background", activationPolicy: .prohibited,
                  executablePath: nil),
            .init(bundleIdentifier: DockWindowEligibilityPolicy.selfBundleIdentifier, appName: "ProperWM",
                  activationPolicy: .accessory, executablePath: nil,
                  bundleURL: URL(fileURLWithPath: "/Applications/ProperWM.app")),
            .init(bundleIdentifier: "com.valvesoftware.steam.helper", appName: "Steam Helper",
                  activationPolicy: .accessory, executablePath: nil, bundleURL: URL(fileURLWithPath:
                    "/Application Support/Steam/Steam.AppBundle/Steam/Contents/Frameworks/Steam Helper.app")),
            .init(bundleIdentifier: "test.helper", appName: "Helper", activationPolicy: .accessory,
                  executablePath: nil, bundleURL: URL(fileURLWithPath: "/Applications/Host.app/Contents/Helpers/Helper.app")),
            .init(bundleIdentifier: "test.unbundled", appName: "Unbundled", activationPolicy: .accessory,
                  executablePath: nil)
        ]
        for source in ["seed", "scan", "launchRetry"] {
            for application in applications {
                let reader = AdmissionWindowReader()
                let tracker = admissionTracker(reader: reader)
                defer { tracker.stop() }
                tracker.runAdmissionForTesting(source: source, application: application)
                for task in tracker.pendingInventoryWorkForTesting { await task.value }
                XCTAssertTrue(StripItem.openWindows(from: tracker.snapshot).isEmpty, source)
                XCTAssertTrue(tracker.diagnosticApps().isEmpty, source)
            }
        }
    }

    private func admissionTracker(reader: AdmissionWindowReader) -> AppTracker {
        let pid = NSRunningApplication.current.processIdentifier
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: "/unused"), maxFileSize: 1024, archiveCount: 0))
        return AppTracker(inventoryLog: log, reader: reader, processProvider: LifecycleProcess(),
                          cgSnapshotProvider: {
                              let ids = Set(reader.state.withLock { $0.windowID.map { [$0] } ?? [] })
                              return .init(allWindowIDs: ids, onScreenWindowIDs: ids, windowIDsByPID: [pid: ids],
                                           alphaByWindowID: Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }))
                          }, onScreenWindowIDsProvider: {
                              Set(reader.state.withLock { $0.windowID.map { [$0] } ?? [] })
                          })
    }

    private func tracker(reader: LifecycleReader, process: LifecycleProcess = LifecycleProcess()) -> AppTracker {
        let pid = NSRunningApplication.current.processIdentifier
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [77], onScreenWindowIDs: [77],
            windowIDsByPID: [pid: [77]], alphaByWindowID: [77: 1])
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: "/unused"), maxFileSize: 1024, archiveCount: 0))
        return AppTracker(inventoryLog: log, reader: reader, processProvider: process,
                          cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [77] })
    }

    private func waitForRead(_ reader: LifecycleReader, count: Int = 1) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while reader.state.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(reader.state.withLock { $0.count }, count)
    }

    func testStopRejectsSeedScanAndRetryResultsAlreadyInFlight() async {
        for source in ["seed", "scan", "launchRetry"] {
            let reader = LifecycleReader()
            let tracker = tracker(reader: reader)
            tracker.runAdmissionForTesting(source: source)
            await waitForRead(reader)
            let pending = tracker.pendingInventoryWorkForTesting
            XCTAssertFalse(pending.isEmpty)
            tracker.stop()
            reader.gates[0].signal()
            for task in pending { await task.value }
            XCTAssertTrue(tracker.diagnosticApps().isEmpty, source)
            XCTAssertTrue(tracker.snapshot.windows.isEmpty, source)
            XCTAssertTrue(tracker.lastAdmissionVerdictByPID.isEmpty, source)
            XCTAssertTrue(tracker.absenceProbeTimerPIDsForTesting.isEmpty)
        }
    }

    func testOldReadCannotOverwriteTheNextRun() async {
        for source in ["seed", "scan", "launchRetry"] {
            let reader = LifecycleReader()
            let tracker = tracker(reader: reader)
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source)
            await waitForRead(reader)
            let old = tracker.pendingInventoryWorkForTesting
            tracker.stop()
            tracker.runAdmissionForTesting(source: source)
            await waitForRead(reader, count: 2)
            let current = tracker.pendingInventoryWorkForTesting
            reader.gates[1].signal()
            for task in current { await task.value }
            XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 1"], source)
            reader.gates[0].signal()
            for task in old { await task.value }
            XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 1"], source)
        }
    }

    func testSeedLeavesMainActorAvailableWhileReading() async {
        let reader = LifecycleReader()
        let tracker = tracker(reader: reader)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed")
        await waitForRead(reader)
        XCTAssertFalse(reader.state.withLock { $0.usedMainThread })
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        let pending = tracker.pendingInventoryWorkForTesting
        reader.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 0"])
    }

    func testSeedRejectsAProcessReplacedDuringTheRead() async {
        let reader = LifecycleReader()
        let process = LifecycleProcess()
        let tracker = tracker(reader: reader, process: process)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed")
        await waitForRead(reader)
        let pending = tracker.pendingInventoryWorkForTesting
        process.generation.withLock { $0 += 1 }
        reader.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        XCTAssertTrue(tracker.diagnosticApps().isEmpty)
    }

    func testStopCancelsDelayedRetriesBeforeReading() async {
        let reader = LifecycleReader()
        let tracker = tracker(reader: reader)
        tracker.runAdmissionForTesting(source: "launchRetry", retryDelays: [60, 120])
        let pending = tracker.pendingInventoryWorkForTesting
        XCTAssertEqual(pending.count, 2)
        tracker.stop()
        for task in pending { await task.value }
        XCTAssertEqual(reader.state.withLock { $0.count }, 0)
        XCTAssertTrue(tracker.lastAdmissionVerdictByPID.isEmpty)
    }
}

private final class AdmissionWindowReader: AppTrackerWindowReading, Sendable {
    enum RejectedKind: CaseIterable {
        case empty, untitled, tiny, utility
    }
    struct State {
        var usedMainThread = false
        var windowID: CGWindowID? = 77
        var focused = false
        var reads = 0
    }
    let state = Mutex(State())
    let rejected: RejectedKind?

    init(rejected: RejectedKind? = nil) { self.rejected = rejected }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { read(pid).windowsOrEmpty }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { read(pid) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { read(pid) }
    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation {
        state.withLock {
            guard !cancellation.isCancelled else { return .init(result: .unread(.cannotComplete)) }
            guard $0.focused, let id = $0.windowID else { return .init(result: .none) }
            return .init(result: .window(pid: NSRunningApplication.current.processIdentifier, windowID: id))
        }
    }

    private func read(_ pid: pid_t) -> AXWindowReadResult {
        let values = state.withLock {
            $0.usedMainThread = $0.usedMainThread || Thread.isMainThread
            $0.reads += 1
            return ($0.windowID, $0.focused)
        }
        guard rejected != .empty, let windowID = values.0 else { return .success([]) }
        return .success([AXWindowSnapshot(pid: pid, cgWindowID: windowID,
            titleRead: rejected == .untitled ? .empty : .value("Dashboard"),
            bounds: rejected == .tiny ? CGRect(x: 0, y: 0, width: 10, height: 10)
                : CGRect(x: 40, y: 40, width: 850, height: 780),
            role: kAXWindowRole as String,
            subrole: rejected == .utility ? kAXFloatingWindowSubrole as String : kAXStandardWindowSubrole as String,
            isMinimized: false, isFocusedWindow: values.1, element: AXUIElementCreateApplication(pid))])
    }
}

extension AppTracker {
    func terminateForTesting(pid: pid_t) { handleAppTerminated(pid: pid) }
    var mutationGenerationCountForTesting: Int { mutationGenerations.count }
}

@MainActor
private final class ControlledInventoryLifecycle: WindowInventoryTracking {
    let tracker: AppTracker
    var snapshots: AnyPublisher<DockSnapshot, Never> { tracker.snapshots }
    init(_ tracker: AppTracker) { self.tracker = tracker }
    func start() {}
    func stop() { tracker.stop() }
}

private final class FocusInventoryGate: Sendable {
    struct State {
        var inventoryReads = 0
        var entered = Set<Int>()
    }
    let state = Mutex(State())
    let gates = (0..<2).map { _ in DispatchSemaphore(value: 0) }
    func read(_ attribute: String) {
        if attribute == kAXWindowsAttribute as String { state.withLock { $0.inventoryReads += 1 } }
        guard attribute == kAXTitleAttribute as String else { return }
        let index = state.withLock { value -> Int? in
            let index = value.inventoryReads - 1
            guard gates.indices.contains(index), value.entered.insert(index).inserted else { return nil }
            return index
        }
        if let index { _ = gates[index].wait(timeout: .now() + 3) }
    }
}

private final class FocusLifecycleReader: AppTrackerWindowReading, Sendable {
    struct State {
        var reads = 0
        var result: AXFocusedWindowRead = .window(77)
        var usedMainThread = false
    }
    let state = Mutex(State())
    let gate = DispatchSemaphore(value: 0)
    let blockFirst: Bool
    init(blockFirst: Bool = true) { self.blockFirst = blockFirst }
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .unread(.cannotComplete) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { .unread(.cannotComplete) }
    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation {
        let observedAt = ProcessInfo.processInfo.systemUptime
        let (index, result) = state.withLock { value in
            value.reads += 1
            value.usedMainThread = value.usedMainThread || Thread.isMainThread
            return (value.reads, value.result)
        }
        if blockFirst && index == 1 { _ = gate.wait(timeout: .now() + 3) }
        return AXFocusedWindowObservation(result: result, observedAt: observedAt)
    }
}

private final class FocusListGate: Sendable {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    func read(_ attribute: String) {
        guard attribute == kAXWindowsAttribute as String else { return }
        entered.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 3)
    }
}

private final class CustomFocusGate: Sendable {
    struct State {
        var lists = 0
        var heldFirst = false
        var heldSecond = false
    }
    let state = Mutex(State())
    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    func read(_ attribute: String) {
        let hold = state.withLock { value -> Int in
            if attribute == kAXWindowsAttribute as String {
                value.lists += 1
                if value.lists == 2 { value.heldSecond = true; return 2 }
            }
            if attribute == kAXMinimizedAttribute as String, !value.heldFirst {
                value.heldFirst = true
                return 1
            }
            return 0
        }
        if hold == 1 { _ = first.wait(timeout: .now() + 3) }
        if hold == 2 { _ = second.wait(timeout: .now() + 3) }
    }
}

private final class FamilyRunningApplication: NSRunningApplication, @unchecked Sendable {
    let fixturePID: pid_t
    let eligibility: AppTrackerWindowEligibility.Application
    init(pid: pid_t, identifier: String, policy: NSApplication.ActivationPolicy, path: String) {
        fixturePID = pid
        eligibility = .init(bundleIdentifier: identifier, appName: "Family", activationPolicy: policy,
            executablePath: path + "/Contents/MacOS/Executable", bundleURL: URL(fileURLWithPath: path))
        super.init()
    }
    override var processIdentifier: pid_t { fixturePID }
    override var bundleIdentifier: String? { eligibility.bundleIdentifier }
    override var localizedName: String? { eligibility.appName }
    override var activationPolicy: NSApplication.ActivationPolicy { eligibility.activationPolicy }
    override var bundleURL: URL? { eligibility.bundleURL }
    override var executableURL: URL? { eligibility.executablePath.map { URL(fileURLWithPath: $0) } }
    override var isHidden: Bool { false }
    override var isTerminated: Bool { false }

    static var family: [FamilyRunningApplication] {
        [FamilyRunningApplication(pid: -41000, identifier: "test.Host", policy: .regular, path: "/Applications/Host"),
         FamilyRunningApplication(pid: -42000, identifier: "test.HelperA", policy: .accessory,
                                  path: "/Applications/Host/Contents/Frameworks/HelperA.app"),
         FamilyRunningApplication(pid: -44000, identifier: "test.HelperB", policy: .accessory,
                                  path: "/Applications/Host/Contents/Frameworks/HelperB.app")]
    }
}

private final class FamilyFocusProcess: AppTrackerProcessProviding, Sendable {
    let generations = Mutex<[pid_t: Int64]>([:])
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: generations.withLock { $0[pid] ?? 10 }, startTimeUsec: 1, bundleID: bundleID)
    }
    func applicationOwner(pid: pid_t) -> ApplicationOwnerRead? {
        guard pid == -42000 || pid == -44000 else { return nil }
        return (identity(pid: -41000, bundleID: "test.Host"), FamilyRunningApplication.family[0].eligibility)
    }
}

private final class FamilyFocusAccessibility: AccessibilityOperations, @unchecked Sendable {
    struct State {
        var focused: CGWindowID? = 1001
        var systemError: AXError?
        var systemReads = 0
        var blockAtRead: Int?
        var usedMainThread = false
        var focusedControl = false
        var controlOwner: pid_t?
        var attributes: [String] = []
        var beforeRead: (@Sendable (String) -> Void)?
        var systemTimeoutWrites = 0
    }
    let state = Mutex(State())
    let gate = DispatchSemaphore(value: 0)
    let desktop = BehaviorDesktop(additionalWindows: 1)
    let system = AXUIElementCreateApplication(-47000)
    let control = AXUIElementCreateApplication(-48000)
    let applications = Dictionary(uniqueKeysWithValues: [-41000, -42000, -44000].map { (pid_t($0), AXUIElementCreateApplication(pid_t($0))) })

    init() {
        desktop.state.withLock {
            $0.windows.removeValue(forKey: 1002)
            if let old = $0.windows[3000] {
                $0.windows[3000] = WindowRecord(id: old.id, appID: AppID(rawValue: "HelperB"), pid: -44000,
                    bundleIdentifier: "test.HelperB", title: old.title, bounds: old.bounds, status: .inactive, cgWindowID: 3000)
            }
        }
    }

    func systemWide() -> AXUIElement? { system }
    func isTrusted() -> Bool { true }
    func application(_ pid: pid_t) -> AXUIElement { applications[pid] ?? desktop.application(pid) }
    func pid(_ element: AXUIElement) -> pid_t? {
        if CFEqual(element, control) {
            return state.withLock { value in
                value.controlOwner ?? value.focused.flatMap { desktop.elements[$0] }.flatMap { desktop.pid($0) }
            }
        }
        return applications.first { CFEqual($0.value, element) }?.key ?? desktop.pid(element)
    }
    func windowID(_ element: AXUIElement) -> CGWindowID? { desktop.windowID(element) }
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError {
        if CFEqual(element, system) { state.withLock { $0.systemTimeoutWrites += 1 } }
        return .success
    }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) { (.success, true) }
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { .failure }
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError { .failure }

    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        let name = attribute as String
        let beforeRead = state.withLock { $0.attributes.append(name); return $0.beforeRead }
        beforeRead?(name)
        if CFEqual(element, system) {
            let (result, block) = state.withLock { value -> ((AXError, CFTypeRef?), Bool) in
                value.usedMainThread = value.usedMainThread || Thread.isMainThread
                value.systemReads += 1
                let block = value.systemReads == value.blockAtRead
                if let error = value.systemError { return ((error, nil), block) }
                guard name == kAXFocusedUIElementAttribute as String, let focused = value.focused else { return ((.noValue, nil), block) }
                return ((.success, value.focusedControl ? control : desktop.elements[focused]), block)
            }
            if block { _ = gate.wait(timeout: .now() + 3) }
            return result
        }
        if CFEqual(element, control) {
            if name == kAXRoleAttribute as String { return (.success, kAXTextFieldRole as CFString) }
            if name == kAXWindowAttribute as String {
                return (.success, state.withLock { $0.focused.flatMap { desktop.elements[$0] } })
            }
            return (.noValue, nil)
        }
        if let pid = applications.first(where: { CFEqual($0.value, element) })?.key {
            let windows = desktop.state.withLock { $0.windows.values.filter { $0.pid == pid }.sorted { $0.cgWindowID! < $1.cgWindowID! } }
            if name == kAXWindowsAttribute as String {
                return (.success, windows.compactMap { desktop.elements[$0.cgWindowID!] } as CFArray)
            }
            if name == kAXFocusedWindowAttribute as String || name == kAXMainWindowAttribute as String {
                return (.success, windows.first.flatMap { desktop.elements[$0.cgWindowID!] })
            }
            if name == kAXRoleAttribute as String { return (.success, kAXApplicationRole as CFString) }
            return (.noValue, nil)
        }
        return desktop.copy(element, attribute)
    }
}

private final class OwnedApplicationProcess: AppTrackerProcessProviding, Sendable {
    let parentAlive = Mutex(true)
    let parentGeneration = Mutex(Int64(10))
    let lookups = Mutex(0)
    let batchLookups = Mutex(0)
    let usedMainThread = Mutex(false)
    func applicationOwners(for pids: Set<pid_t>, cancellation: OperationCancellation) -> [pid_t: ApplicationOwnerRead] {
        batchLookups.withLock { $0 += 1 }
        return Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            applicationOwner(pid: pid).map { (pid, $0) }
        })
    }
    func isAlive(pid: pid_t) -> Bool { pid != -43000 || parentAlive.withLock { $0 } }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: isAlive(pid: pid) ? (pid == -43000 ? parentGeneration.withLock { $0 } : 10) : nil, startTimeUsec: 1, bundleID: bundleID)
    }
    func applicationOwner(pid: pid_t) -> (identity: ScanAdmissionDecision.ProcessIdentity, application: AppTrackerWindowEligibility.Application)? {
        lookups.withLock { $0 += 1 }
        usedMainThread.withLock { $0 = $0 || Thread.isMainThread }
        return (identity(pid: -43000, bundleID: "test.Host"),
         .init(bundleIdentifier: "test.Host", appName: "Host", activationPolicy: .regular,
               executablePath: "/Applications/Host/Contents/MacOS/Host", bundleURL: URL(fileURLWithPath: "/Applications/Host")))
    }
}
