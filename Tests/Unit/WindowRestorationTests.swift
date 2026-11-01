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
