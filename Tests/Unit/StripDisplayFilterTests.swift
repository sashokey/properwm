import XCTest

final class StripDisplayFilterTests: XCTestCase {
    private let onA = StripDisplayFilter(scope: "A", connectedUUIDs: ["A", "B"], primaryUUID: "A")
    private let onB = StripDisplayFilter(scope: "B", connectedUUIDs: ["A", "B"], primaryUUID: "A")

    func testLaunchersShowEverywhere() {
        XCTAssertTrue(onA.shows(.launcher))
        XCTAssertTrue(onB.shows(.launcher))
        XCTAssertTrue(StripDisplayFilter.unfiltered.shows(.launcher))
    }

    func testNilScopeShowsEverything() {
        let filter = StripDisplayFilter(scope: nil, connectedUUIDs: ["A", "B"], primaryUUID: "A")
        XCTAssertTrue(filter.shows(.window(displayUUID: "B")))
        XCTAssertTrue(filter.shows(.window(displayUUID: nil)))
        XCTAssertTrue(filter.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertTrue(StripDisplayFilter.unfiltered.shows(.window(displayUUID: "Z")))
    }

    func testWindowShowsOnlyOnItsOwnDisplay() {
        XCTAssertTrue(onA.shows(.window(displayUUID: "A")))
        XCTAssertFalse(onB.shows(.window(displayUUID: "A")))
        XCTAssertTrue(onB.shows(.window(displayUUID: "B")))
        XCTAssertFalse(onA.shows(.window(displayUUID: "B")))
    }

    /// 有运行圆点但没窗口（应用级兜底卡 / 在运行的保留占位）→ 只在一条上：窗口最后所在的屏，读不到落主屏。
    func testRunningWithoutWindowShowsOnItsHomeElsePrimary() {
        XCTAssertTrue(onA.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertFalse(onB.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertFalse(onA.shows(.runningWithoutWindow(displayUUID: "B")))
        XCTAssertTrue(onB.shows(.runningWithoutWindow(displayUUID: "B")))
        XCTAssertTrue(onA.shows(.runningWithoutWindow(displayUUID: "GONE")))
    }

    /// 读不到位置 → 落主屏（菜单栏屏），别的屏不画。
    func testUnknownDisplayFallsToPrimary() {
        XCTAssertTrue(onA.shows(.window(displayUUID: nil)))
        XCTAssertFalse(onB.shows(.window(displayUUID: nil)))
    }

    /// 归属键指向已拔掉的屏 → 同样落主屏。
    func testDisconnectedDisplayFallsToPrimary() {
        XCTAssertTrue(onA.shows(.window(displayUUID: "GONE")))
        XCTAssertFalse(onB.shows(.window(displayUUID: "GONE")))
    }

    /// 没有主屏（屏表为空）时未知归属 / 无窗口图标哪都不画——已接受：这只在没有任何屏时发生。
    func testNoPrimaryHidesUnknownEverywhere() {
        let filter = StripDisplayFilter(scope: "A", connectedUUIDs: [], primaryUUID: nil)
        XCTAssertFalse(filter.shows(.window(displayUUID: nil)))
        XCTAssertFalse(filter.shows(.window(displayUUID: "A")))
        XCTAssertFalse(filter.shows(.runningWithoutWindow(displayUUID: nil)))
        XCTAssertTrue(filter.shows(.launcher))
    }
}
