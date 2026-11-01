import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

private final class RestorationFixture: WindowRestorationAccess {
    let writes = Mutex(0)
    let writtenFrames = Mutex<[CGRect]>([])
    let current: CGRect?
    let result: AXWindowFrameWriteResult
    let start: timeval?
    let onRead: @Sendable () -> Void

    init(current: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 68),
         result: AXWindowFrameWriteResult = .failure(reason: .writeFailed(attribute: .size, error: .cannotComplete), rollback: .notRequested),
         start: timeval? = timeval(tv_sec: 10, tv_usec: 0), onRead: @escaping @Sendable () -> Void = {}) {
        self.current = current
        self.result = result
        self.start = start
        self.onRead = onRead
    }
    func processStartTime(pid: pid_t) -> timeval? { start }
    func capture(_ key: WindowLiftAvoidance.WindowKey) -> Int? { 1 }
    func frame(_ handle: Int) -> CGRect? { onRead(); return current }
    func write(_ frame: CGRect, to handle: Int, matching current: CGRect) -> AXWindowFrameWriteResult {
        writes.withLock { $0 += 1 }
        writtenFrames.withLock { $0.append(frame) }
        return result
    }
}

@MainActor
private final class RestorationHost: WindowLiftAvoidanceHost {
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] { [] }
    func windowGeometryChanged() {}
}

@MainActor
final class WindowRestorationTests: XCTestCase {
    private let key = WindowLiftAvoidance.WindowKey(pid: 42, cgWindowID: 1)
    private let frames = WindowRestorationFrames(nativeAppKit: CGRect(x: 0, y: 0, width: 100, height: 100),
        targetAppKit: CGRect(x: 0, y: 32, width: 100, height: 68), nativeQuartz: CGRect(x: 0, y: 0, width: 100, height: 100),
        targetQuartz: CGRect(x: 0, y: 0, width: 100, height: 68), primaryScreenHeight: 100)

    func testFailedOrUnverifiedRestorationRemainsPending() {
        for result in [AXWindowFrameWriteResult.failure(reason: .writeFailed(attribute: .size, error: .cannotComplete), rollback: .notRequested),
                       .failure(reason: .verificationUnavailable, rollback: .notRequested),
                       .failure(reason: .verificationMismatch(expected: frames.nativeQuartz, actual: frames.targetQuartz), rollback: .notRequested)] {
            let access = RestorationFixture(result: result)
            XCTAssertEqual(WindowRestorer(access: access).restore(key: key, frames: frames, expectedStartTime: nil, liveWindowKeys: [key]), .retry)
            XCTAssertEqual(access.writes.withLock { $0 }, 1)
        }
    }

    func testConfirmedWriteCompletesRestoration() {
        let access = RestorationFixture(result: .success(actualFrame: frames.nativeQuartz))
        XCTAssertEqual(WindowRestorer(access: access).restore(key: key, frames: frames, expectedStartTime: nil, liveWindowKeys: [key]), .handled)
    }

    func testRestorationUsesTheNewGeometryAfterFullscreenReturnRecovery() {
        let native = CGRect(x: 2560, y: 0, width: 2560, height: 1410)
        let target = CGRect(x: 2560, y: 34, width: 2560, height: 1376)
        let recoveredFrames = WindowRestorationFrames(
            nativeAppKit: native, targetAppKit: target, primaryScreenHeight: 1440
        )
        let expectedNative = CGRect(x: 2560, y: 30, width: 2560, height: 1410)
        let access = RestorationFixture(
            current: CGRect(x: 2560, y: 30, width: 2560, height: 1376),
            result: .success(actualFrame: expectedNative)
        )
        XCTAssertEqual(WindowRestorer(access: access).restore(
            key: key, frames: recoveredFrames, expectedStartTime: nil, liveWindowKeys: [key]
        ), .handled)
        XCTAssertEqual(access.writtenFrames.withLock { $0 }, [expectedNative])
    }

    func testMovedOrReusedWindowsAreNeverWritten() {
        let moved = RestorationFixture(current: CGRect(x: 40, y: 40, width: 30, height: 30))
        XCTAssertEqual(WindowRestorer(access: moved).restore(key: key, frames: frames, expectedStartTime: nil, liveWindowKeys: [key]), .handled)
        XCTAssertEqual(moved.writes.withLock { $0 }, 0)
        let reused = RestorationFixture(start: timeval(tv_sec: 20, tv_usec: 0))
        XCTAssertEqual(WindowRestorer(access: reused).restore(key: key, frames: frames,
            expectedStartTime: timeval(tv_sec: 10, tv_usec: 0), liveWindowKeys: [key]), .handled)
        XCTAssertEqual(reused.writes.withLock { $0 }, 0)
    }

    func testUnavailableProcessIdentityDoesNotDiscardALiveWindow() {
        let access = RestorationFixture(start: nil)
        XCTAssertEqual(WindowRestorer(access: access).restore(key: key, frames: frames,
            expectedStartTime: timeval(tv_sec: 10, tv_usec: 0), liveWindowKeys: [key]), .retry)
        XCTAssertEqual(access.writes.withLock { $0 }, 0)
    }

    func testCancellationAfterReadingGeometryPreventsRestorationWrite() {
        let cancellation = OperationCancellation()
        let access = RestorationFixture(onRead: { cancellation.cancel() })
        XCTAssertEqual(WindowRestorer(access: access).restore(key: key, frames: frames,
            expectedStartTime: nil, liveWindowKeys: [key], cancellation: cancellation), .retry)
        XCTAssertEqual(access.writes.withLock { $0 }, 0)
    }

    func testPermissionFreezePreservesRestorationUntilOldWorkDrains() async {
        let attempts = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let controller = WindowLiftAvoidanceController(host: RestorationHost(), isTrustedProbe: { true },
            restoreWindow: { _, _, _, _, _ in
                let count = attempts.withLock { $0 += 1; return $0 }
                if count == 1 { _ = gate.wait(timeout: .now() + 2) }
                return .handled
            }, restorationWindowKeys: { nil })
        controller.enqueueRestorationForTesting(key: key, frames: frames)
        let stopping = Task { await controller.stopAndRestore() }
        let deadline = ContinuousClock.now + .seconds(2)
        while attempts.withLock({ $0 }) == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        controller.beginPermissionUncertainty()
        gate.signal()
        await stopping.value
        XCTAssertEqual(controller.pendingRestorationCountForTesting, 1)
        await controller.restoreAndStopForPermissionRecovery()
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(controller.pendingRestorationCountForTesting, 0)
    }

    func testControllerRetriesFailureAndRemovesOnlyConfirmedRestoration() async {
        let attempts = Mutex(0)
        let controller = WindowLiftAvoidanceController(host: RestorationHost(), isTrustedProbe: { true },
            restoreWindow: { _, _, _, _, _ in attempts.withLock { count in count += 1; return count < 2 ? .retry : .handled } },
            restorationWindowKeys: { nil })
        controller.enqueueRestorationForTesting(key: key, frames: frames)
        await controller.stopAndRestore()
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(controller.pendingRestorationCountForTesting, 0)
    }

    func testControllerStopsRetryingWithoutDroppingFailedState() async {
        let attempts = Mutex(0)
        let controller = WindowLiftAvoidanceController(host: RestorationHost(), isTrustedProbe: { true },
            restoreWindow: { _, _, _, _, _ in attempts.withLock { $0 += 1 }; return .retry }, restorationWindowKeys: { nil })
        controller.enqueueRestorationForTesting(key: key, frames: frames)
        await controller.stopAndRestore()
        XCTAssertEqual(attempts.withLock { $0 }, 3)
        XCTAssertEqual(controller.pendingRestorationCountForTesting, 1)
    }
}

private final class LiftProbeFixture: WindowLiftWindowProbing, Sendable {
    struct State {
        var now: TimeInterval = 200
        var captures = 0
        var frameRequests: [Set<WindowLiftAvoidance.WindowKey>] = []
        var frames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
    }
    let state = Mutex(State())
    func capture(on contexts: [WindowLiftAvoidanceContext], excludingPID: pid_t, includeLiveWindowKeys: Bool,
                 includesTiles: Bool, trackedKeys: Set<WindowLiftAvoidance.WindowKey>) -> WindowLiftCGScanResult {
        state.withLock {
            $0.captures += 1
            return .init(candidatesByScreenIndex: [:], onScreenFrames: $0.frames, liveWindowKeys: nil)
        }
    }
    func frames(for keys: Set<WindowLiftAvoidance.WindowKey>) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        state.withLock {
            $0.frameRequests.append(keys)
            return $0.frames.filter { keys.contains($0.key) }
        }
    }
}

@MainActor
private final class LiftContextHost: WindowLiftAvoidanceHost {
    var contexts: [WindowLiftAvoidanceContext] = []
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] { contexts }
    func windowGeometryChanged() {}
}

@MainActor
final class WindowLiftContextLifecycleTests: XCTestCase {
    func testCancelledWriterIsReleasedAfterItFinishes() async {
        let host = LiftContextHost()
        let a = context(x: 0)
        let key = WindowLiftAvoidance.WindowKey(pid: -501, cgWindowID: 1)
        let gate = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        let writer = Task.detached {
            _ = await AsyncWorkScope.performBlocking {
                started.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 2)
            }
        }
        let controller = WindowLiftAvoidanceController(host: host, isTrustedProbe: { true },
            restoreWindow: { _, _, _, _, _ in .handled }, restorationWindowKeys: { nil })
        await waitUntil { started.withLock { $0 } }
        controller.installSessionForTesting(key: key, context: a, frames: frames(a), state: state(frames(a)), writer: writer)
        controller.clearSessionForTesting(key)
        XCTAssertEqual(controller.retainedWriterCountForTesting, 1)
        gate.signal()
        await waitUntil { controller.retainedWriterCountForTesting == 0 }
        await controller.stopAndRestore()
    }

    private func context(x: CGFloat) -> WindowLiftAvoidanceContext {
        let frame = CGRect(x: x, y: 0, width: 1200, height: 800)
        return .init(geometry: .init(screenFrame: frame, visibleFrame: frame, taskbarTop: 32),
                     screenCGFrame: frame, visibleCGFrame: frame, primaryScreenHeight: 800)
    }

    private func frames(_ context: WindowLiftAvoidanceContext) -> WindowRestorationFrames {
        let native = context.geometry.visibleFrame
        return .init(nativeAppKit: native,
            targetAppKit: CGRect(x: native.minX, y: 34, width: native.width, height: native.height - 34),
            primaryScreenHeight: 800)
    }

    private func state(_ frames: WindowRestorationFrames, settledAt: TimeInterval = 100) -> WindowLiftAvoidance.SessionState {
        .lifted(.init(generation: 1, nativeFrame: frames.nativeAppKit, adjustedFrame: frames.targetAppKit,
                     reliftCount: 0, settledAt: settledAt, standoffRounds: 0))
    }

    func testDisplayRemovalGeometryChangeAndReorderingPreserveUnaffectedSessions() async {
        let a = context(x: 0)
        let b = context(x: 1200)
        let keyA = WindowLiftAvoidance.WindowKey(pid: -501, cgWindowID: 1)
        let keyB = WindowLiftAvoidance.WindowKey(pid: -502, cgWindowID: 2)
        for (next, expected) in [([b], Set([keyA])), ([b, a], Set<WindowLiftAvoidance.WindowKey>()),
                                 ([a, context(x: 2400)], Set([keyB])), ([], Set([keyA, keyB]))] {
            let restored = Mutex<Set<WindowLiftAvoidance.WindowKey>>([])
            let host = LiftContextHost()
            host.contexts = next
            let controller = WindowLiftAvoidanceController(host: host, isTrustedProbe: { true },
                restoreWindow: { key, _, _, _, _ in restored.withLock { _ = $0.insert(key) }; return .handled },
                restorationWindowKeys: { nil })
            controller.reconcileContextsForTesting([a, b])
            controller.installSessionForTesting(key: keyA, context: a, frames: frames(a), state: state(frames(a)))
            controller.installSessionForTesting(key: keyB, context: b, frames: frames(b), state: state(frames(b)))
            controller.reconcileContextsForTesting(next)
            for task in controller.pendingWorkForTesting { await task.value }
            XCTAssertEqual(restored.withLock { $0 }, expected)
            for (key, context) in [(keyA, a), (keyB, b)] where !expected.contains(key) {
                XCTAssertEqual(controller.sessionForTesting(key), state(frames(context)))
            }
            await controller.stopAndRestore()
        }
    }

    func testSecondDisplayRestorationWaitsForItsCancelledWriter() async {
        let a = context(x: 0)
        let b = context(x: 1200)
        let keyA = WindowLiftAvoidance.WindowKey(pid: -501, cgWindowID: 1)
        let keyB = WindowLiftAvoidance.WindowKey(pid: -502, cgWindowID: 2)
        let calls = Mutex<[WindowLiftAvoidance.WindowKey]>([])
        let restoreGate = DispatchSemaphore(value: 0)
        let writerGate = DispatchSemaphore(value: 0)
        let writing = Mutex(false)
        let writer = Task.detached {
            _ = await AsyncWorkScope.performBlocking {
                writing.withLock { $0 = true }
                _ = writerGate.wait(timeout: .now() + 3)
            }
        }
        let host = LiftContextHost()
        let controller = WindowLiftAvoidanceController(host: host, isTrustedProbe: { true },
            restoreWindow: { key, _, _, _, _ in
                calls.withLock { $0.append(key) }
                if key == keyA { _ = restoreGate.wait(timeout: .now() + 3) }
                return .handled
            }, restorationWindowKeys: { nil })
        await waitUntil { writing.withLock { $0 } }
        controller.reconcileContextsForTesting([a, b])
        controller.installSessionForTesting(key: keyA, context: a, frames: frames(a), state: state(frames(a)))
        controller.installSessionForTesting(key: keyB, context: b, frames: frames(b), state: state(frames(b)), writer: writer)
        controller.reconcileContextsForTesting([b])
        await waitUntil { calls.withLock { $0 == [keyA] } }
        let first = controller.pendingWorkForTesting
        controller.reconcileContextsForTesting([])
        restoreGate.signal()
        for task in first { await task.value }
        XCTAssertEqual(calls.withLock { $0 }, [keyA])
        XCTAssertEqual(controller.pendingRestorationCountForTesting, 1)
        writerGate.signal()
        await controller.stopAndRestore()
        XCTAssertEqual(calls.withLock { $0 }, [keyA, keyB])
        XCTAssertEqual(controller.pendingRestorationCountForTesting, 0)
    }

    func testSettledWindowHasNoFastReadsAndRespondsToEventsAndFallback() async {
        let host = LiftContextHost()
        let a = context(x: 0)
        host.contexts = [a]
        let key = WindowLiftAvoidance.WindowKey(pid: -501, cgWindowID: 1)
        let frames = frames(a)
        let probe = LiftProbeFixture()
        probe.state.withLock { $0.frames = [key: frames.targetQuartz] }
        let controller = WindowLiftAvoidanceController(host: host, isTrustedProbe: { true },
            restoreWindow: { _, _, _, _, _ in .handled }, restorationWindowKeys: { nil }, windowProbe: probe,
            uptime: { probe.state.withLock { $0.now } })
        controller.reconcileContextsForTesting([a])
        controller.installSessionForTesting(key: key, context: a, frames: frames, state: state(frames))
        controller.enableMonitoringForTesting()
        XCTAssertEqual(controller.pollIntervalForTesting, 1)
        XCTAssertNil(controller.trackedIntervalForTesting)
        for _ in 0..<100 { controller.probeTrackedFramesForTesting() }
        XCTAssertTrue(probe.state.withLock { $0.frameRequests.isEmpty })
        controller.pollForTesting()
        for task in controller.pendingWorkForTesting { await task.value }
        XCTAssertEqual(probe.state.withLock { $0.captures }, 1)
        XCTAssertNotNil(controller.sessionForTesting(key))
        controller.geometryEventForTesting()
        for task in controller.pendingWorkForTesting { await task.value }
        XCTAssertEqual(probe.state.withLock { $0.captures }, 2)
        probe.state.withLock { $0.frames[key] = CGRect(x: 200, y: 200, width: 500, height: 400); $0.now += 2 }
        controller.pollForTesting()
        for task in controller.pendingWorkForTesting { await task.value }
        XCTAssertNil(controller.sessionForTesting(key))
        await controller.stopAndRestore()
    }

    func testFastProbeIncludesOnlySettlingWindowsAndExpires() async {
        let host = LiftContextHost()
        let a = context(x: 0)
        host.contexts = [a]
        let old = WindowLiftAvoidance.WindowKey(pid: -501, cgWindowID: 1)
        let recent = WindowLiftAvoidance.WindowKey(pid: -502, cgWindowID: 2)
        let frames = frames(a)
        let probe = LiftProbeFixture()
        probe.state.withLock { $0.frames = [old: frames.targetQuartz, recent: frames.targetQuartz] }
        let controller = WindowLiftAvoidanceController(host: host, isTrustedProbe: { true },
            restoreWindow: { _, _, _, _, _ in .handled }, restorationWindowKeys: { nil }, windowProbe: probe,
            uptime: { probe.state.withLock { $0.now } })
        controller.reconcileContextsForTesting([a])
        controller.installSessionForTesting(key: old, context: a, frames: frames, state: state(frames))
        controller.installSessionForTesting(key: recent, context: a, frames: frames, state: state(frames, settledAt: 199.5))
        controller.enableMonitoringForTesting()
        XCTAssertEqual(controller.pollIntervalForTesting, 0.2)
        XCTAssertEqual(controller.trackedIntervalForTesting, 0.05)
        controller.probeTrackedFramesForTesting()
        for task in controller.pendingWorkForTesting { await task.value }
        XCTAssertEqual(probe.state.withLock { $0.frameRequests }, [Set([recent])])
        probe.state.withLock { $0.now = 202 }
        controller.refreshCadenceForTesting()
        XCTAssertEqual(controller.pollIntervalForTesting, 1)
        XCTAssertNil(controller.trackedIntervalForTesting)
        XCTAssertNotNil(controller.sessionForTesting(old))
        XCTAssertNotNil(controller.sessionForTesting(recent))
        await controller.stopAndRestore()
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }
}
