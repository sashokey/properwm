import CoreGraphics
import XCTest

/// 按压反馈的纯判定。
///
/// 背景（owner 2026-08-11 报「按下去有粘滞感」）：旧实现把回弹挂在 `.onTapGesture` 上，
/// 而 SwiftUI 的 TapGesture 是**鼠标抬起**才触发的——整个「按压」发生在点击已经结束之后。
/// 现在改由 `DragGesture(minimumDistance: 0)` 在按下瞬间驱动，抬起时按下面的规则收尾。
final class ChipPressFeedbackTests: XCTestCase {

    // MARK: - 最短保持

    /// 一次极快的点击（按下到抬起只有几毫秒）如果立刻弹回，那一下 0.93 缩放根本看不见。
    /// 这就是旧实现里那个 90ms 定时器的本意，改成按下驱动之后必须原样保留。
    func testVeryFastClickIsHeldUpToTheMinimum() {
        let hold = ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 100.005)
        XCTAssertEqual(hold, ChipPressDecision.minimumHold - 0.005, accuracy: 1e-9)
    }

    /// 按下已经超过最短保持时长：抬起就该立刻弹回，不再额外拖时间——多拖就是新的粘滞感。
    func testSlowClickReleasesImmediately() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 100.5),
            0
        )
    }

    func testExactlyAtMinimumReleasesImmediately() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(
                pressedAt: 100.0,
                releasedAt: 100.0 + ChipPressDecision.minimumHold
            ),
            0
        )
    }

    /// 没记到按下时刻（力度触控 / 中键预览那种只有脉冲、没有 mouse-down 的路径）：补足整段，
    /// 否则那一档反馈会一帧都不显示。
    func testMissingPressTimestampHoldsFullMinimum() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(pressedAt: nil, releasedAt: 100.0),
            ChipPressDecision.minimumHold
        )
    }

    /// 抬起早于按下（时钟异常 / 状态错序）绝不能算出负数——负延迟会让调度立即触发，
    /// 等于悄悄把最短保持这条规则关掉。
    func testReleaseBeforePressNeverReturnsNegative() {
        let hold = ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 99.0)
        XCTAssertEqual(hold, ChipPressDecision.minimumHold)
        XCTAssertGreaterThanOrEqual(hold, 0)
    }

    // MARK: - 常量边界

    /// 看门狗必须明显长于最短保持：它防的是「`onEnded` 永远不来」（SwiftUI 在重排挪动 chip 时
    /// 会取消手势），不是正常点击。两者一旦靠近，正常的长按会被误当成卡住而提前弹回。
    func testWatchdogIsWellAboveMinimumHold() {
        XCTAssertGreaterThan(ChipPressDecision.maximumHold, ChipPressDecision.minimumHold * 5)
    }

    /// 缩放值是改动前的字面值，刻意不动（owner 已签收的观感）。
    func testPressedScaleMatchesPreviousLiteral() {
        XCTAssertEqual(ChipPressDecision.pressedScale, 0.93)
    }

    /// 最短保持沿用旧的 90ms。
    func testMinimumHoldMatchesPreviousTimer() {
        XCTAssertEqual(ChipPressDecision.minimumHold, 0.09, accuracy: 1e-9)
    }
}
