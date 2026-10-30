import XCTest

/// 这组用例存在的唯一理由：2026-08-20 owner 报的「从抽屉往任务条拖图标，整条任务条一圈黑边」。
/// 成因是投放高亮**把玻璃镜面亮边整个换掉**。下面第一条就是锁这个的。
final class DockPanelRimPlanTests: XCTestCase {

    /// 高亮**不得**再拿掉玻璃亮边——高亮是叠上去的。
    func testGlassRimSurvivesHighlight() {
        XCTAssertTrue(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: true, usesSystemVariant: false))
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: false, usesSystemVariant: false))
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: true, usesSystemVariant: true),
                       "the Dock material draws its own rim")
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: false, usesSystemVariant: true))
    }

    /// 玻璃路径：平时那圈边归 `DockGlassRim`，主题描边宽度必须是 0
    /// （不是画一条看不见的线——0 宽等价于不进视图树，同 `.blur(radius: 0)` 那条规矩）。
    func testGlassPathDrawsThemeStrokeOnlyWhenHighlighted() {
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: true, highlighted: false, lineWidth: 0.5),
            0
        )
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: true, highlighted: true, lineWidth: 1),
            1
        )
    }

    /// 毛玻璃路径（macOS 12–25）：主题描边**就是**那圈边，平时和高亮都得画。
    func testFrostedPathAlwaysDrawsTheThemeStroke() {
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: false, highlighted: false, lineWidth: 0.5),
            0.5
        )
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: false, highlighted: true, lineWidth: 1),
            1
        )
    }
}
