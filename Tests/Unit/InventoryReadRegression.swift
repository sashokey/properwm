import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization
import XCTest

private final class InventoryRegressionAX: AccessibilityOperations, @unchecked Sendable {
    let app = AXUIElementCreateApplication(-42420)
    let window = AXUIElementCreateApplication(-42421)
    let minimizedResult: AXError
    let pidValue: pid_t = -42420
    let id: CGWindowID = 88
    let windowReadCount = Mutex(0)
    let windowRead: @Sendable (Int) -> Bool

    init(minimizedResult: AXError, windowRead: @escaping @Sendable (Int) -> Bool = { _ in true }) {
        self.minimizedResult = minimizedResult
        self.windowRead = windowRead
    }

    func isTrusted() -> Bool { true }
    func application(_ pid: pid_t) -> AXUIElement { app }
    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        switch attribute as String {
        case kAXWindowsAttribute:
            let count = windowReadCount.withLock { $0 += 1; return $0 }
            return (.success, (windowRead(count) ? [window] : []) as CFArray)
        case kAXFocusedWindowAttribute: return (.noValue, nil)
        case kAXMinimizedAttribute:
            return minimizedResult == .success ? (.success, kCFBooleanTrue) : (minimizedResult, nil)
        case kAXTitleAttribute: return (.success, "Window" as CFString)
        case kAXRoleAttribute: return (.success, kAXWindowRole as CFString)
        case kAXSubroleAttribute: return (.success, kAXStandardWindowSubrole as CFString)
        case kAXPositionAttribute:
            var point = CGPoint(x: 10, y: 20)
            return (.success, AXValueCreate(.cgPoint, &point))
        case kAXSizeAttribute:
            var size = CGSize(width: 500, height: 400)
            return (.success, AXValueCreate(.cgSize, &size))
        default: return (.attributeUnsupported, nil)
        }
    }
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { .notImplemented }
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError { .notImplemented }
    func pid(_ element: AXUIElement) -> pid_t? { pidValue }
    func windowID(_ element: AXUIElement) -> CGWindowID? { CFEqual(element, window) ? id : nil }
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError { .success }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) { (.success, false) }
}

private struct InventoryRegressionProcess: AppTrackerProcessProviding {
    let seconds: Int64
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: seconds, startTimeUsec: 0, bundleID: bundleID)
    }
}

private final class InventoryMutableProcess: AppTrackerProcessProviding {
    let generation: Mutex<ProcessGeneration?>
    init(_ generation: ProcessGeneration?) { self.generation = Mutex(generation) }
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        let current = generation.withLock { $0 }
        return .init(pid: pid, startTimeSec: current?.seconds, startTimeUsec: current?.microseconds, bundleID: bundleID)
    }
}

@MainActor
final class InventoryReadRegression: XCTestCase {
    private let pid: pid_t = -42420
    private let frame = CGRect(x: 10, y: 20, width: 500, height: 400)

    func testInventoryPreservesCancellationFromItsOuterBudget() {
        let cancellation = OperationCancellation()
        cancellation.cancel()
        let fixture = InventoryRegressionAX(minimizedResult: .success)
        let reader = AXWindowReader(accessibility: fixture).withOperationBudget(
            OperationReadBudget(maximumDuration: 1, cancellation: cancellation))
        guard case .unread(.cannotComplete) = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.1) else {
            return XCTFail("A cancelled inventory read must remain unread")
        }
        XCTAssertEqual(fixture.windowReadCount.withLock { $0 }, 0)
    }

    func testCaptureStopsRetryingWhenItsOuterBudgetIsCancelled() {
        let cancellation = OperationCancellation()
        let fixture = InventoryRegressionAX(minimizedResult: .success, windowRead: { _ in
            cancellation.cancel()
            return false
        })
        let reader = AXWindowReader(accessibility: fixture).withOperationBudget(
            OperationReadBudget(maximumDuration: 1, cancellation: cancellation))
        XCTAssertNil(reader.captureHandle(for: .init(pid: pid, title: nil, bounds: nil, cgWindowID: 88), attempts: 3, messagingTimeout: 0.1))
        XCTAssertEqual(fixture.windowReadCount.withLock { $0 }, 1)
    }

    func testCaptureRetriesShareTheRemainingOuterBudget() {
        let now = Mutex<TimeInterval>(0)
        let fixture = InventoryRegressionAX(minimizedResult: .success, windowRead: { _ in
            now.withLock { $0 += 0.03 }
            return false
        })
        let reader = AXWindowReader(accessibility: fixture).withOperationBudget(
            OperationReadBudget(maximumDuration: 0.05, cancellation: OperationCancellation(), uptime: { now.withLock { $0 } }))
        XCTAssertNil(reader.captureHandle(for: .init(pid: pid, title: nil, bounds: nil, cgWindowID: 88), attempts: 3, messagingTimeout: 0.1))
        XCTAssertEqual(fixture.windowReadCount.withLock { $0 }, 2)
    }

    func testCaptureRejectsAWindowReadAfterItsOuterDeadline() {
        let now = Mutex<TimeInterval>(0)
        let fixture = InventoryRegressionAX(minimizedResult: .success, windowRead: { _ in
            now.withLock { $0 = 1 }
            return true
        })
        let reader = AXWindowReader(accessibility: fixture).withOperationBudget(
            OperationReadBudget(maximumDuration: 0.05, cancellation: OperationCancellation(), uptime: { now.withLock { $0 } }))
        XCTAssertNil(reader.captureHandle(for: .init(pid: pid, title: nil, bounds: nil, cgWindowID: 88), attempts: 3, messagingTimeout: 0.1))
        XCTAssertEqual(fixture.windowReadCount.withLock { $0 }, 1)
    }

    func testInventoryKeepsItsTwoSecondLimitInsideALongerOuterBudget() {
        let now = Mutex<TimeInterval>(0)
        let fixture = InventoryRegressionAX(minimizedResult: .success, windowRead: { _ in
            now.withLock { $0 = 3 }
            return true
        })
        let reader = AXWindowReader(accessibility: fixture).withOperationBudget(
            OperationReadBudget(maximumDuration: 10, cancellation: OperationCancellation(), uptime: { now.withLock { $0 } }))
        guard case .unread(.cannotComplete) = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.1) else {
            return XCTFail("The inventory suboperation must retain its own limit")
        }
        XCTAssertEqual(fixture.windowReadCount.withLock { $0 }, 1)
    }

    func testCaptureCanFindAWindowOnALaterAttemptWithinItsBudget() {
        let now = Mutex<TimeInterval>(0)
        let fixture = InventoryRegressionAX(minimizedResult: .success, windowRead: { attempt in
            now.withLock { $0 += 0.01 }
            return attempt == 3
        })
        let reader = AXWindowReader(accessibility: fixture).withOperationBudget(
            OperationReadBudget(maximumDuration: 0.05, cancellation: OperationCancellation(), uptime: { now.withLock { $0 } }))
        XCTAssertNotNil(reader.captureHandle(for: .init(pid: pid, title: nil, bounds: nil, cgWindowID: 88), attempts: 3, messagingTimeout: 0.1))
        XCTAssertEqual(fixture.windowReadCount.withLock { $0 }, 3)
    }

    func testUnreadMinimizedAttributePreservesKnownMinimizedSeat() throws {
        let fixture = InventoryRegressionAX(minimizedResult: .cannotComplete)
        let read = inventory(fixture)
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(app(seatID: 88, isMinimized: true, everSeenVisible: false))

        _ = tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cg([88]), now: Date(),
            eligible: read.windows, readOutcome: read.outcome)
        tracker.rebuildSnapshotForTesting()

        let seat = try XCTUnwrap(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[88])
        XCTAssertTrue(seat.isMinimized, "An unread AXMinimized attribute must preserve the known minimized state")
        XCTAssertFalse(seat.everSeenVisible, "An unread attribute is not evidence that this seat was ever visible")
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.status, .minimized)
    }

    func testUnreadMinimizedAttributeDoesNotSplitKnownBackgroundTab() throws {
        let fixture = InventoryRegressionAX(minimizedResult: .cannotComplete)
        let read = inventory(fixture)
        let tracker = makeTracker()
        defer { tracker.stop() }
        var seeded = app(seatID: 77, isMinimized: true, everSeenVisible: true)
        seeded.windowsByID[77]?.formerCgIDs = [88]
        tracker.installFixtureForTesting(seeded)
        let knownActiveTab = AXWindowSnapshot(pid: pid, cgWindowID: 77, titleRead: .value("Active tab"),
            bounds: frame, role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
            isMinimized: true, isFocusedWindow: false, element: AXUIElementCreateApplication(-42422),
            isMinimizedRead: true)

        _ = tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cg([77, 88]), now: Date(),
            eligible: [knownActiveTab] + read.windows,
            readOutcome: read.outcome.kind == .unread ? read.outcome : .success(count: 2))

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [77],
            "A known background tab must not gain a separate seat merely because AXMinimized timed out")
    }

    func testPIDReuseBeforeNewReadDoesNotAttachNewWindowsToOldApp() async throws {
        let fixture = InventoryRegressionAX(minimizedResult: .success)
        let snapshotProvider = cg([88])
        let tracker = makeTracker(reader: AXWindowReader(accessibility: fixture), processSeconds: 2,
            cgSnapshot: snapshotProvider)
        defer { tracker.stop() }
        var seeded = app(seatID: 77, isMinimized: false, everSeenVisible: true)
        seeded.processGeneration = ProcessGeneration(timeval(tv_sec: 1, tv_usec: 0))
        tracker.installFixtureForTesting(seeded)
        tracker.rebuildSnapshotForTesting()

        tracker.scheduleEventReadForTesting(pid: pid, source: .frontmostPoll)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while tracker.hasPendingEventReadForTesting(pid: pid), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pid), "The mock read must finish within the bound")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[88],
            "A read for process generation 2 must not land in the AppEntry belonging to generation 1")
        XCTAssertNil(tracker.snapshot.windows[WindowID(rawValue: "cgw-88")],
            "The old app must not publish the replacement process's window using its old generation")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid))
        XCTAssertNil(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")])
    }

    func testUnavailableIdentityPreservesKnownAppUntilItsGenerationRecovers() async {
        let provider = InventoryMutableProcess(nil)
        let reader = AXWindowReader(accessibility: InventoryRegressionAX(minimizedResult: .success))
        let tracker = makeTracker(reader: reader, cgSnapshot: cg([77, 88]), process: provider)
        defer { tracker.stop() }
        var seeded = app(seatID: 77, isMinimized: false, everSeenVisible: true)
        seeded.processGeneration = ProcessGeneration(timeval(tv_sec: 1, tv_usec: 0))
        tracker.installFixtureForTesting(seeded)
        tracker.rebuildSnapshotForTesting()
        tracker.scheduleEventReadForTesting(pid: pid, source: .frontmostPoll)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[77])
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[88])
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pid))
        provider.generation.withLock { $0 = ProcessGeneration(timeval(tv_sec: 1, tv_usec: 0)) }
        tracker.scheduleEventReadForTesting(pid: pid, source: .frontmostPoll)
        let deadline = ContinuousClock.now + .seconds(2)
        while tracker.hasPendingEventReadForTesting(pid: pid), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[88])
    }

    func testMicrosecondGenerationChangeRetiresTheOldApp() {
        let provider = InventoryMutableProcess(ProcessGeneration(timeval(tv_sec: 1, tv_usec: 2)))
        let tracker = makeTracker(process: provider)
        defer { tracker.stop() }
        var seeded = app(seatID: 77, isMinimized: false, everSeenVisible: true)
        seeded.processGeneration = ProcessGeneration(timeval(tv_sec: 1, tv_usec: 1))
        tracker.installFixtureForTesting(seeded)
        tracker.rebuildSnapshotForTesting()
        tracker.scheduleEventReadForTesting(pid: pid, source: .frontmostPoll)
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid))
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
    }

    func testTransientMinimizedReadIsUnreadAndHealthyReadRecovers() {
        for error in [AXError.cannotComplete, .failure, .invalidUIElement, .apiDisabled] {
            let read = inventory(InventoryRegressionAX(minimizedResult: error))
            XCTAssertEqual(read.outcome, .unread(errorCode: error.rawValue))
        }
        let healthy = inventory(InventoryRegressionAX(minimizedResult: .success))
        XCTAssertEqual(healthy.outcome, .success(count: 1))
        XCTAssertEqual(healthy.windows.first?.isMinimized, true)
    }

    func testUnsupportedMinimizedAttributeStillAdmitsOrdinaryWindows() {
        for error in [AXError.attributeUnsupported, .noValue] {
            let read = inventory(InventoryRegressionAX(minimizedResult: error))
            XCTAssertEqual(read.outcome, .success(count: 1))
            XCTAssertEqual(read.windows.first?.isMinimized, false)
            XCTAssertEqual(read.windows.first?.title, "Window")
        }
    }

    private func inventory(_ fixture: InventoryRegressionAX) -> (windows: [AXWindowSnapshot], outcome: InventoryAXReadOutcome) {
        let result = AXWindowReader(accessibility: fixture).inventoryWindows(forPID: fixture.pidValue,
            messagingTimeout: 0.1)
        switch result {
        case let .success(windows): return (windows, .success(count: windows.count))
        case let .unread(error): return ([], .unread(errorCode: error.rawValue))
        }
    }

    private func app(seatID: CGWindowID, isMinimized: Bool, everSeenVisible: Bool) -> AppEntry {
        let seat = WindowEntry(cgWindowID: seatID, token: "known-seat", title: "Window", bounds: frame,
            isMinimized: isMinimized, isFocused: false, everSeenVisible: everSeenVisible)
        return AppEntry(pid: pid, bundleIdentifier: "example.inventory.fixture", appName: "Old app",
            activationPolicy: .regular, executablePath: "/Applications/Old.app/Contents/MacOS/Old",
            windowsByID: [seatID: seat], windowOrder: [seatID], isHidden: false)
    }

    private func cg(_ ids: Set<CGWindowID>) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(allWindowIDs: ids, onScreenWindowIDs: [],
            windowIDsByPID: [pid: ids], alphaByWindowID: [:])
    }

    private func makeTracker(reader: any AppTrackerWindowReading = AXWindowReader(),
        processSeconds: Int64 = 1, cgSnapshot: AppTrackerCGWindowSnapshot = .failed,
        process: (any AppTrackerProcessProviding)? = nil) -> AppTracker {
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            maxFileSize: 1_000_000, archiveCount: 1))
        let tracker = AppTracker(inventoryLog: log, reader: reader,
            processProvider: process ?? InventoryRegressionProcess(seconds: processSeconds),
            cgSnapshotProvider: { cgSnapshot }, onScreenWindowIDsProvider: { [] })
        tracker.setFrontmostPIDForTesting(pid)
        return tracker
    }
}
