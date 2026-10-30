import XCTest
@testable import macos_dock_cc_v2

final class StripWheelScrollTests: XCTestCase {
    private func input(dx: CGFloat = 0,
                       dy: CGFloat,
                       precise: Bool,
                       inverted: Bool) -> StripWheelScroll.Input {
        StripWheelScroll.Input(deltaX: dx, deltaY: dy,
                               hasPreciseDeltas: precise, isDirectionInverted: inverted)
    }

    // MARK: - 不接管的情形

    func testNoVerticalComponentIsNotClaimed() {
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 12, dy: 0, precise: true, inverted: true)))
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dy: 0, precise: false, inverted: false)))
    }

    /// 横向为主的手势必须放行给 `NSScrollView`——它的惯性和橡皮筋是原生的，接管过来只会更差。
    func testHorizontallyDominantGestureIsNotClaimed() {
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 30, dy: 4, precise: true, inverted: true)))
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: -30, dy: 4, precise: true, inverted: true)))
        // 相等也算横向为主：只有严格「垂直压过横向」才接管。
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 8, dy: 8, precise: true, inverted: true)))
    }

    func testVerticallyDominantGestureIsClaimedEvenWithSomeHorizontalDrift() {
        XCTAssertNotNil(StripWheelScroll.horizontalStep(for: input(dx: 3, dy: 20, precise: true, inverted: true)))
    }

    // MARK: - 离散滚轮（带格子的鼠标）

    /// 这四格必须与改动前 `sign * deltaY * 56` 的结果逐值一致——手感是已签收的。
    func testDiscreteWheelMatchesTheShippedFeel() {
        let table: [(dy: CGFloat, inverted: Bool, expected: CGFloat)] = [
            (1, false, 56), (-1, false, -56),
            (1, true, -56), (-1, true, 56),
        ]
        for row in table {
            XCTAssertEqual(
                StripWheelScroll.horizontalStep(for: input(dy: row.dy, precise: false, inverted: row.inverted)),
                row.expected,
                "dy=\(row.dy) inverted=\(row.inverted)"
            )
        }
    }

    func testDiscreteWheelStepIsClamped() {
        XCTAssertEqual(StripWheelScroll.horizontalStep(for: input(dy: 10, precise: false, inverted: false)),
                       StripWheelScroll.maxStep)
        XCTAssertEqual(StripWheelScroll.horizontalStep(for: input(dy: -10, precise: false, inverted: false)),
                       -StripWheelScroll.maxStep)
    }

    // MARK: - 连续事件（触控板 / 妙控鼠标 / 平滑滚轮）

    /// 连续事件的 delta 本来就是点数：1:1 搬运，既不乘 `wheelSpeed` 也不封顶
    /// （惯性阶段的大 delta 正是它该有的手感）。
    func testPreciseDeltasArePassedThroughOneToOne() {
        let table: [(dy: CGFloat, inverted: Bool, expected: CGFloat)] = [
            (7, false, 7), (-7, false, -7),
            (7, true, -7), (-7, true, 7),
            (400, true, -400),
        ]
        for row in table {
            XCTAssertEqual(
                StripWheelScroll.horizontalStep(for: input(dy: row.dy, precise: true, inverted: row.inverted)),
                row.expected,
                "dy=\(row.dy) inverted=\(row.inverted)"
            )
        }
    }

    /// 同一个 delta，连续事件绝不能被当成离散滚轮放大——那会一下甩到头。
    func testPreciseDeltasAreNotAmplifiedLikeAWheelNotch() {
        let precise = StripWheelScroll.horizontalStep(for: input(dy: 1, precise: true, inverted: false))
        let discrete = StripWheelScroll.horizontalStep(for: input(dy: 1, precise: false, inverted: false))
        XCTAssertEqual(precise, 1)
        XCTAssertEqual(discrete, StripWheelScroll.wheelSpeed)
    }
}
