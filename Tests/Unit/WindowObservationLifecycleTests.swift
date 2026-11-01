import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

private final class ObservationFixture: WindowObservationSession, Sendable {
    let calls = Mutex<[Bool]>([])
    let windowCalls = Mutex(0)
    let removals = Mutex(0)
    let transientFailures = Mutex(0)
    let registered = Mutex<[AXElementKey: Set<String>]>([:])
    let gate = DispatchSemaphore(value: 0)
    let blockWindows: Bool
    @MainActor var attachments = 0
    @MainActor var detachments = 0

    init(blockWindows: Bool = false) { self.blockWindows = blockWindows }
    func add(_ notification: String, element: AXElementKey?) -> AXError {
        calls.withLock { $0.append(Thread.isMainThread) }
        if let element {
            windowCalls.withLock { $0 += 1 }
            if blockWindows { _ = gate.wait(timeout: .now() + 2) }
            let failed = transientFailures.withLock { value in
                guard value > 0 else { return false }
                value -= 1
                return true
            }
            if failed { return .cannotComplete }
            _ = registered.withLock { $0[element, default: []].insert(notification) }
        }
        return .success
    }
    func remove(_ notification: String, element: AXElementKey) {
        calls.withLock { $0.append(Thread.isMainThread) }
        _ = registered.withLock { $0[element]?.remove(notification) }
        removals.withLock { $0 += 1 }
    }
    @MainActor func attach() { attachments += 1 }
    @MainActor func detach() { detachments += 1 }
}

@MainActor
final class WindowObservationLifecycleTests: XCTestCase {
    func testGeometryRegistrationRetriesTransientFailureOnFallbackWithoutBusyLoop() async {
        let fixture = ObservationFixture()
        fixture.transientFailures.withLock { $0 = 1 }
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in fixture }, readFocused: { _ in .window(key) })
        observer.start(pid: 42)
        await waitUntil { fixture.windowCalls.withLock { $0 } == 3 }
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(fixture.registered.withLock { $0[key]?.count }, 2)
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 3)
        observer.retryUnavailableObservation()
        await waitUntil { fixture.registered.withLock { $0[key]?.count == 3 } }
        for task in observer.pendingWorkForTesting { await task.value }
        observer.retryUnavailableObservation()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 6)
        observer.stop()
    }

    func testUnavailableFocusPreservesRegistrationAndRetriesOnlyUntilRecovery() async {
        let session = ObservationFixture()
        let old = AXElementKey(e: AXUIElementCreateApplication(42))
        let next = AXElementKey(e: AXUIElementCreateApplication(43))
        let response = Mutex(FocusedWindowRead.window(old))
        let reads = Mutex(0)
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in session }, readFocused: { _ in
            reads.withLock { $0 += 1 }
            return response.withLock { $0 }
        })
        observer.start(pid: 42)
        await waitUntil { session.registered.withLock { $0[old]?.count == 3 } }
        response.withLock { $0 = .unavailable }
        observer.activate(pid: 42)
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(session.registered.withLock { $0[old]?.count }, 3)
        XCTAssertEqual(session.removals.withLock { $0 }, 0)
        response.withLock { $0 = .window(next) }
        observer.retryUnavailableObservation()
        await waitUntil { session.registered.withLock { $0[next]?.count == 3 } }
        for task in observer.pendingWorkForTesting { await task.value }
        observer.retryUnavailableObservation()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(reads.withLock { $0 }, 3)
        XCTAssertTrue(session.registered.withLock { $0[old]?.isEmpty == true })
        observer.stop()
    }

    func testGeometryObserverStopsFurtherRegistrationAndRejectsOldCallbacksAfterSwitch() async {
        let old = ObservationFixture(blockWindows: true)
        let replacement = ObservationFixture()
        let callbacks = Mutex<[@Sendable (AXElementKey, String) -> Void]>([])
        let observer = FrontmostWindowGeometryObserver(makeSession: { pid, receive in
            callbacks.withLock { $0.append(receive) }
            return pid == 42 ? old : replacement
        }, readFocused: { .window(AXElementKey(e: AXUIElementCreateApplication($0))) })
        var geometryEvents = 0
        observer.onEvent = { if case .geometryChanged = $0 { geometryEvents += 1 } }
        observer.start(pid: 42)
        await waitUntil { old.windowCalls.withLock { $0 } == 1 }
        let pending = observer.pendingWorkForTesting
        observer.activate(pid: 43)
        old.gate.signal()
        for task in pending { await task.value }
        await waitUntil { replacement.windowCalls.withLock { $0 } == 3 }
        XCTAssertEqual(old.windowCalls.withLock { $0 }, 1)
        XCTAssertEqual(old.detachments, 1)
        let receivers = callbacks.withLock { $0 }
        XCTAssertEqual(receivers.count, 2)
        receivers[0](AXElementKey(e: AXUIElementCreateApplication(42)), kAXWindowMovedNotification)
        receivers[1](AXElementKey(e: AXUIElementCreateApplication(43)), kAXWindowMovedNotification)
        await waitUntil { geometryEvents == 1 }
        XCTAssertFalse(old.calls.withLock { $0.contains(true) })
        XCTAssertFalse(replacement.calls.withLock { $0.contains(true) })
        observer.stop()
        XCTAssertEqual(replacement.detachments, 1)
    }

    func testGeometryObserverSkipsObsoleteStartupsQueuedBehindABlockedFactory() async {
        let session = ObservationFixture()
        let pids = Mutex<[pid_t]>([])
        let gate = DispatchSemaphore(value: 0)
        let observer = FrontmostWindowGeometryObserver(makeSession: { pid, _ in
            pids.withLock { $0.append(pid) }
            if pid == 42 { _ = gate.wait(timeout: .now() + 2) }
            return session
        }, readFocused: { _ in .none })
        observer.start(pid: 42)
        await waitUntil { pids.withLock { !$0.isEmpty } }
        for pid in Int32(43)...62 { observer.activate(pid: pid) }
        gate.signal()
        await waitUntil { session.attachments == 1 }
        XCTAssertEqual(pids.withLock { $0 }, [42, 62])
        XCTAssertEqual(session.attachments, 1)
        XCTAssertEqual(session.calls.withLock { $0.count }, 2)
        observer.stop()
    }

    func testGeometryObserverStopDuringFocusedReadNeverRegistersTheLateWindow() async {
        let session = ObservationFixture()
        let reading = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in session }, readFocused: { pid in
            reading.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 2)
            return .window(AXElementKey(e: AXUIElementCreateApplication(pid)))
        })
        observer.start(pid: 42)
        await waitUntil { reading.withLock { $0 } }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertEqual(session.windowCalls.withLock { $0 }, 0)
        XCTAssertEqual(session.detachments, 1)
    }

    func testGeometryObserverCoalescesFocusChangesAndReleasesOldWindow() async {
        let session = ObservationFixture()
        let old = AXElementKey(e: AXUIElementCreateApplication(42))
        let next = AXElementKey(e: AXUIElementCreateApplication(43))
        let focused = Mutex(old)
        let reads = Mutex(0)
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in session }, readFocused: { _ in
            reads.withLock { $0 += 1 }
            return .window(focused.withLock { $0 })
        })
        observer.start(pid: 42)
        await waitUntil { session.windowCalls.withLock { $0 } == 3 }
        focused.withLock { $0 = next }
        for _ in 0..<100 { observer.activate(pid: 42) }
        await waitUntil { session.registered.withLock { $0[next]?.count == 3 } }
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertLessThanOrEqual(reads.withLock { $0 }, 3)
        XCTAssertTrue(session.registered.withLock { $0[old]?.isEmpty == true })
        XCTAssertEqual(session.removals.withLock { $0 }, 3)
        observer.stop()
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    func testWindowRegistrationQueuedDuringStartupRunsOffMain() async {
        let fixture = ObservationFixture()
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        observer.start()
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        await waitUntil { observer.isCovered(cgWindowID: 1) }
        XCTAssertEqual(fixture.calls.withLock { $0.count }, 6)
        XCTAssertFalse(fixture.calls.withLock { $0.contains(true) })
        observer.stop()
        XCTAssertEqual(fixture.detachments, 1)
    }

    func testStopDuringRegistrationRejectsLateCompletion() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        var reports = 0
        observer.onSubscriptionAttempt = { _ in reports += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        await waitUntil { fixture.windowCalls.withLock { $0 } > 0 }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        for _ in 0..<4 { fixture.gate.signal() }
        for task in pending { await task.value }
        XCTAssertFalse(observer.isActive)
        XCTAssertFalse(observer.isCovered(cgWindowID: 1))
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 1)
        XCTAssertFalse(fixture.calls.withLock { $0.contains(true) })
    }
    func testCancelledStartupNeverAttachesOrRegistersASession() async {
        let fixture = ObservationFixture()
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 2)
            return fixture
        })
        observer.start()
        await waitUntil { entered.withLock { $0 } }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertEqual(fixture.attachments, 0)
        XCTAssertTrue(fixture.calls.withLock { $0.isEmpty })
    }

    func testRetiringWindowDuringRegistrationStopsFurtherSubscriptions() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        var reports = 0
        observer.onSubscriptionAttempt = { _ in reports += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        await waitUntil { fixture.windowCalls.withLock { $0 } == 1 }
        let pending = observer.pendingWorkForTesting
        _ = observer.retainSubscriptions(keep: [])
        for _ in 0..<4 { fixture.gate.signal() }
        for task in pending { await task.value }
        await waitUntil { fixture.removals.withLock { $0 } == 4 }
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 1)
        XCTAssertTrue(fixture.registered.withLock { $0.values.allSatisfy(\.isEmpty) })
        XCTAssertFalse(observer.isCovered(cgWindowID: 1))
        XCTAssertEqual(reports, 0)
        observer.stop()
    }

    func testReplacingWindowDuringRegistrationReleasesOldElementSubscriptions() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        let old = AXElementKey(e: AXUIElementCreateApplication(42))
        let replacement = AXElementKey(e: AXUIElementCreateApplication(43))
        var reports = 0
        observer.onSubscriptionAttempt = { _ in reports += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(old.e, cgWindowID: 1)
        await waitUntil { fixture.windowCalls.withLock { $0 } == 1 }
        _ = observer.registerWindow(replacement.e, cgWindowID: 1)
        for _ in 0..<5 { fixture.gate.signal() }
        await waitUntil { observer.isCovered(cgWindowID: 1) }
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 5)
        XCTAssertTrue(fixture.registered.withLock { $0[old]?.isEmpty == true })
        XCTAssertEqual(fixture.registered.withLock { $0[replacement]?.count }, 4)
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(observer.subscribedElement(cgWindowID: 1).map { AXElementKey(e: $0.element) }, replacement)
        observer.stop()
    }

    func testNotificationsFromAnOldSessionCannotAffectARestartedObserver() async {
        let fixture = ObservationFixture()
        let callbacks = Mutex<[@Sendable (AXElementKey, String) -> Void]>([])
        let observer = AppWindowObserver(pid: 42, makeSession: { _, receive in
            callbacks.withLock { $0.append(receive) }
            return fixture
        })
        var focusChanges = 0
        observer.onFocusedWindowChanged = { _ in focusChanges += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        observer.stop()
        observer.start()
        await waitUntil { observer.isActive }
        let receivers = callbacks.withLock { $0 }
        XCTAssertEqual(receivers.count, 2)
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        receivers[0](key, kAXFocusedWindowChangedNotification)
        receivers[1](key, kAXFocusedWindowChangedNotification)
        await waitUntil { focusChanges > 0 }
        XCTAssertEqual(focusChanges, 1)
        observer.stop()
    }

}

extension FrontmostWindowGeometryObserver {
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
}
