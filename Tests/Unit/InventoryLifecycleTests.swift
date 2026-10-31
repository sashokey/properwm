import AppKit
import ApplicationServices
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
