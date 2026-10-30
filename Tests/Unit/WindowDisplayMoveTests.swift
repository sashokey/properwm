import CoreGraphics
import XCTest

final class WindowDisplayMoveTests: XCTestCase {
    private let a = WindowDisplayAttribution.Display(
        uuid: "A",
        cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleCGFrame: CGRect(x: 0, y: 25, width: 1000, height: 775)
    )
    private let b = WindowDisplayAttribution.Display(
        uuid: "B",
        cgFrame: CGRect(x: 1000, y: -200, width: 2000, height: 1200),
        visibleCGFrame: CGRect(x: 1000, y: -175, width: 2000, height: 1175)
    )

    /// 成败看归属屏：AppKit 修正了几 pt 仍算到了；落回来源屏才算没到。
    func testLandedOnTargetJudgesByDisplayNotByPixels() {
        let table = WindowDisplayAttribution.Table(displays: [a, b], primaryUUID: "A")
        let nudged = CGRect(x: 1106, y: -70, width: 400, height: 300)   // 比请求帧偏了 6/5 pt
        XCTAssertTrue(WindowDisplayMove.landedOnTarget(actual: nudged, target: "B", table: table))
        let stayed = CGRect(x: 100, y: 125, width: 400, height: 300)
        XCTAssertFalse(WindowDisplayMove.landedOnTarget(actual: stayed, target: "B", table: table))
    }

    func testKeepsOffsetFromSourceVisibleOrigin() {
        let window = CGRect(x: 100, y: 125, width: 400, height: 300)   // 相对 A 可用区偏移 (100, 100)
        let moved = WindowDisplayMove.targetFrame(window: window, from: a, to: b)
        XCTAssertEqual(moved, CGRect(x: 1100, y: -75, width: 400, height: 300))
    }

    func testClampsIntoTargetVisibleArea() {
        let window = CGRect(x: 1900, y: 800, width: 400, height: 300)  // 在 B 的右下角外
        let moved = WindowDisplayMove.targetFrame(window: window, from: b, to: a)
        XCTAssertEqual(moved, CGRect(x: 600, y: 500, width: 400, height: 300))
        XCTAssertTrue(a.visibleCGFrame.contains(moved))
    }

    func testShrinksWindowLargerThanTarget() {
        let window = CGRect(x: 1000, y: -175, width: 1800, height: 1000)
        let moved = WindowDisplayMove.targetFrame(window: window, from: b, to: a)
        XCTAssertEqual(moved.size, CGSize(width: 1000, height: 775))
        XCTAssertEqual(moved.origin, a.visibleCGFrame.origin)
    }

    func testUnknownSourceCentersInTarget() {
        let window = CGRect(x: 5000, y: 5000, width: 400, height: 300)
        let moved = WindowDisplayMove.targetFrame(window: window, from: nil, to: a)
        XCTAssertEqual(moved.midX, a.visibleCGFrame.midX, accuracy: 1)
        XCTAssertEqual(moved.midY, a.visibleCGFrame.midY, accuracy: 1)
        XCTAssertEqual(moved.size, window.size)
    }
}
