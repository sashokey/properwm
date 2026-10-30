import XCTest
@testable import macos_dock_cc_v2

final class WindowTitleSettleTests: XCTestCase {

    private func feed(_ settle: inout WindowTitleSettle, _ title: String, at t: TimeInterval) -> [String: String] {
        settle.observe(rawTitles: ["w": title], now: t)
    }

    func testFirstChangesFollowImmediately() {
        var settle = WindowTitleSettle()
        XCTAssertEqual(feed(&settle, "A", at: 0), [:])
        XCTAssertEqual(feed(&settle, "B", at: 1), [:])
        XCTAssertEqual(feed(&settle, "C", at: 2), [:])
        XCTAssertEqual(feed(&settle, "D", at: 3), [:])   // 第 3 次变化仍照常跟
        XCTAssertNil(settle.nextReleaseAt)
    }

    func testFourthChangeInsideWindowFreezesOnDisplayedTitle() {
        var settle = WindowTitleSettle()
        _ = feed(&settle, "A", at: 0)
        _ = feed(&settle, "B", at: 1)
        _ = feed(&settle, "A", at: 2)
        _ = feed(&settle, "B", at: 3)
        XCTAssertEqual(feed(&settle, "A", at: 4), ["w": "B"])   // 第 4 次：冻结在 B
        XCTAssertEqual(settle.nextReleaseAt, 6)                 // 4 + quietInterval
    }

    func testContinuousFlippingNeverReleases() {
        var settle = WindowTitleSettle()
        var t: TimeInterval = 0
        var titles = ["A", "B"]
        for _ in 0..<20 {
            _ = feed(&settle, titles[0], at: t)
            titles.swapAt(0, 1)
            t += 1
        }
        // 20 秒里每秒横跳；从第 4 次起一直冻结在同一份
        XCTAssertEqual(feed(&settle, "A", at: t), ["w": "B"])
        XCTAssertEqual(feed(&settle, "A", at: t + 1.5), ["w": "B"])   // 安静 1.5s 还不够
        XCTAssertEqual(feed(&settle, "A", at: t + 2), [:])            // 安静满 2s 才放开
    }

    func testReleasesToLatestAfterQuietInterval() {
        var settle = WindowTitleSettle()
        _ = feed(&settle, "A", at: 0)
        _ = feed(&settle, "B", at: 1)
        _ = feed(&settle, "A", at: 2)
        _ = feed(&settle, "B", at: 3)
        XCTAssertEqual(feed(&settle, "Final", at: 4), ["w": "B"])
        XCTAssertEqual(feed(&settle, "Final", at: 5.9), ["w": "B"])   // 还没安静够
        XCTAssertEqual(feed(&settle, "Final", at: 6), [:])            // 放开，直接到最新值
        XCTAssertNil(settle.nextReleaseAt)
    }

    func testChangesOutsideMemoryWindowDoNotCount() {
        var settle = WindowTitleSettle()
        _ = feed(&settle, "A", at: 0)
        _ = feed(&settle, "B", at: 1)
        _ = feed(&settle, "C", at: 2)
        _ = feed(&settle, "D", at: 3)
        // 6 秒窗口滑过前三次变化后，再变仍是「窗口内第 1 次」
        XCTAssertEqual(feed(&settle, "E", at: 10), [:])
        XCTAssertEqual(feed(&settle, "F", at: 10.5), [:])
    }

    func testForgetsCardsThatLeftAndStartsNewOnesAtCurrentTitle() {
        var settle = WindowTitleSettle()
        _ = settle.observe(rawTitles: ["w": "A"], now: 0)
        for (i, title) in ["B", "A", "B", "A"].enumerated() {
            _ = settle.observe(rawTitles: ["w": title], now: TimeInterval(i + 1))
        }
        XCTAssertNotNil(settle.nextReleaseAt)
        // 卡离开一轮再回来：历史清零，不再冻结
        XCTAssertEqual(settle.observe(rawTitles: [:], now: 5), [:])
        XCTAssertNil(settle.nextReleaseAt)
        XCTAssertEqual(settle.observe(rawTitles: ["w": "B"], now: 5.5), [:])
        XCTAssertEqual(settle.observe(rawTitles: ["w": "A"], now: 6), [:])
    }

    func testFrozenCardsAreIndependent() {
        var settle = WindowTitleSettle()
        _ = settle.observe(rawTitles: ["x": "A", "y": "P"], now: 0)
        for (i, title) in ["B", "A", "B", "A"].enumerated() {
            _ = settle.observe(rawTitles: ["x": title, "y": "P"], now: TimeInterval(i + 1))
        }
        // x 第 5 次变化仍冻结在 B；y 只是第 1 次变化，照常跟
        XCTAssertEqual(settle.observe(rawTitles: ["x": "C", "y": "Q"], now: 5), ["x": "B"])
    }
}
