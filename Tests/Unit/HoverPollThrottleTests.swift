import XCTest

final class HoverPollThrottleTests: XCTestCase {
    func testFirstEventRunsImmediately() {
        var t = HoverPollThrottle(minInterval: 1.0 / 30.0)
        XCTAssertEqual(t.eventArrived(now: 100), .run)
    }

    func testEventInsideWindowSchedulesOneTrailing() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        guard case .scheduleTrailing(let after) = t.eventArrived(now: 100.010) else {
            return XCTFail("应挂收尾")
        }
        XCTAssertEqual(after, 0.023, accuracy: 0.0001)
        // 收尾已挂，窗口内后续事件全部丢弃。
        XCTAssertEqual(t.eventArrived(now: 100.015), .drop)
        XCTAssertEqual(t.eventArrived(now: 100.020), .drop)
    }

    func testTrailingFiredResetsWindowFromFireTime() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        _ = t.eventArrived(now: 100.010)
        t.trailingFired(now: 100.033)
        // 收尾之后一个新窗口：立刻来的事件仍被节流，窗口满后放行。
        XCTAssertNotEqual(t.eventArrived(now: 100.040), .run)
        XCTAssertEqual(t.eventArrived(now: 100.070), .run)
    }

    func testQuietGapRunsImmediately() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        XCTAssertEqual(t.eventArrived(now: 105), .run)
    }

    func testResetClearsPendingTrailing() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        _ = t.eventArrived(now: 100.010)   // trailing scheduled
        t.reset()
        XCTAssertEqual(t.eventArrived(now: 100.011), .run)
    }
}
