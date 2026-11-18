import AppKit
import Foundation
import Synchronization
import XCTest

@MainActor
private final class FairnessRestorationHost: WindowLiftAvoidanceHost {
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] { [] }
    func windowGeometryChanged() {}
}

@MainActor
final class RestorationFairnessRegressionTests: XCTestCase {
    func testRepeatedRestorationBatchesEventuallyVisitEveryPendingWindow() async {
        let host = FairnessRestorationHost()
        let responsive = WindowLiftAvoidance.WindowKey(pid: -42000, cgWindowID: 80)
        let calls = Mutex<[WindowLiftAvoidance.WindowKey: Int]>([:])
        let now = Mutex<TimeInterval>(0)
        let controller = WindowLiftAvoidanceController(
            host: host,
            isTrustedProbe: { true },
            restoreWindow: { key, _, _, _, _ in
                calls.withLock { $0[key, default: 0] += 1 }
                if key == responsive { return .handled }
                Thread.sleep(forTimeInterval: 0.15)
                return .retry
            },
            restorationWindowKeys: { nil },
            uptime: { now.withLock { $0 } }
        )
        let frames = WindowRestorationFrames(
            nativeAppKit: CGRect(x: 0, y: 0, width: 1200, height: 800),
            targetAppKit: CGRect(x: 0, y: 34, width: 1200, height: 766),
            primaryScreenHeight: 800,
            processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1))
        )
        for index in 1...responsive.cgWindowID {
            let key = WindowLiftAvoidance.WindowKey(pid: -42000, cgWindowID: CGWindowID(index))
            controller.pendingRestorations[key] = frames
        }
        controller.isEnabled = true
        defer { controller.beginPermissionUncertainty() }
        controller.poll()
        await controller.restoreTask?.value
        XCTAssertNil(calls.withLock { $0[responsive] })
        XCTAssertNotNil(controller.pendingRestorations[responsive])
        for batch in 1...4 {
            now.withLock { $0 = TimeInterval(batch * 10) }
            controller.poll()
            await controller.restoreTask?.value
            if controller.pendingRestorations[responsive] == nil { break }
        }
        XCTAssertGreaterThan(calls.withLock { $0[responsive, default: 0] }, 0,
                             "A responsive pending window was starved by the same slow prefix on every bounded batch")
        XCTAssertNil(controller.pendingRestorations[responsive])
    }
}
