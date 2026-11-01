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
    }
    let state = Mutex(State())
    let rejected: RejectedKind?

    init(rejected: RejectedKind? = nil) { self.rejected = rejected }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { read(pid).windowsOrEmpty }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { read(pid) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { read(pid) }

    private func read(_ pid: pid_t) -> AXWindowReadResult {
        let windowID = state.withLock {
            $0.usedMainThread = $0.usedMainThread || Thread.isMainThread
            return $0.windowID
        }
        guard rejected != .empty, let windowID else { return .success([]) }
        return .success([AXWindowSnapshot(pid: pid, cgWindowID: windowID,
            titleRead: rejected == .untitled ? .empty : .value("Dashboard"),
            bounds: rejected == .tiny ? CGRect(x: 0, y: 0, width: 10, height: 10)
                : CGRect(x: 40, y: 40, width: 850, height: 780),
            role: kAXWindowRole as String,
            subrole: rejected == .utility ? kAXFloatingWindowSubrole as String : kAXStandardWindowSubrole as String,
            isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(pid))])
    }
}

extension AppTracker {
    func terminateForTesting(pid: pid_t) { handleAppTerminated(pid: pid) }
    var mutationGenerationCountForTesting: Int { mutationGenerations.count }
}
