import CoreGraphics
import XCTest

final class PanelGeometryTests: XCTestCase {
    private let metrics = PanelLayoutMetrics.properWM

    func testBottomDockVisibleFrameChangeDoesNotMoveBottomPanelsVertically() {
        let hidden = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let shown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869)
        )

        let hiddenLayout = layout(on: hidden)
        let shownLayout = layout(on: shown)

        XCTAssertEqual(hiddenLayout.minY, shownLayout.minY)
    }

    func testSideDockVisibleFrameChangeDoesNotMoveOrResizeBottomPanelsHorizontally() {
        let hidden = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let leftDockShown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 90, y: 0, width: 1422, height: 949)
        )
        let rightDockShown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1422, height: 949)
        )

        let hiddenLayout = layout(on: hidden)
        for candidate in [layout(on: leftDockShown), layout(on: rightDockShown)] {
            XCTAssertEqual(candidate.minX, hiddenLayout.minX)
            XCTAssertEqual(candidate.width, hiddenLayout.width)
        }
    }

    func testBottomAnchoringUsesNonZeroScreenMinY() {
        let upperScreen = screen(frame: CGRect(x: -488, y: 982, width: 2560, height: 1440))
        let lowerScreen = screen(frame: CGRect(x: -2408, y: -640, width: 1920, height: 1080))

        XCTAssertEqual(layout(on: upperScreen).minY, upperScreen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
        XCTAssertEqual(layout(on: lowerScreen).minY, lowerScreen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
    }

    func testDockFrameKeepsOriginalBottomCoordinate() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))

        let dock = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: metrics)

        XCTAssertEqual(dock.minY, -12, "bottomGap 8 − shadowPadding 20，与档位高度无关")
        XCTAssertEqual(dock.height, 94, "中档 54 + 2×20")
    }

    func testWindowTitleTooltipAnchorsVisibleBubbleAbovePillAndCenters() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let anchor = CGRect(x: 700, y: 20, width: 160, height: 34)
        let frame = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 300, height: 60),
            tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        )
        let bubble = frame.insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                                   dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(bubble.minY, anchor.maxY + WindowTitleTooltipStyle.native.tipGap)
        XCTAssertEqual(bubble.midX, anchor.midX)
    }

    func testWindowTitleTooltipClampsVisibleBubbleInsideNonZeroScreenEdges() {
        let screen = screen(frame: CGRect(x: -1512, y: 982, width: 1512, height: 982))
        let size = CGSize(width: 300, height: 60)
        let left = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: screen.frame.minX, y: 1000, width: 40, height: 30),
            size: size, tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        ).insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                  dy: PanelGeometry.windowTitleTooltipShadowPadding)
        let right = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: screen.frame.maxX - 40, y: 1000, width: 40, height: 30),
            size: size, tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        ).insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                  dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(left.minX, screen.frame.minX + PanelGeometry.windowTitleTooltipScreenMargin)
        XCTAssertEqual(right.maxX, screen.frame.maxX - PanelGeometry.windowTitleTooltipScreenMargin)
    }

    func testWindowTitleTooltipRespectsTopUsableY() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 0
        )
        let frame = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: 700, y: 900, width: 100, height: 30),
            size: CGSize(width: 300, height: 60),
            tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        )
        let bubble = frame.insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                                   dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(bubble.maxY, screen.topUsableY)
    }

    private let sampleHeights: [DockPanelHeight] = [32, 40, 47, 54, 63, 80, 120].map { DockPanelHeight(clamping: $0) }

    func testClampingRoundsAndClampsToTheRange() {
        XCTAssertEqual(DockPanelHeight(clamping: 31.4).points, 32)
        XCTAssertEqual(DockPanelHeight(clamping: 40.6).points, 41)
        XCTAssertEqual(DockPanelHeight(clamping: 120.4).points, 120)
        XCTAssertEqual(DockPanelHeight(clamping: 200).points, 120)
        XCTAssertEqual(DockPanelHeight(clamping: 0).points, 32)
        XCTAssertEqual(DockPanelHeight(clamping: .nan).points, 54)
        XCTAssertEqual(DockPanelHeight(clamping: .infinity).points, 54)
        XCTAssertEqual(DockPanelHeight.minimum, 32)
        XCTAssertEqual(DockPanelHeight.maximum, 120)
    }

    func testLegacyTierMigrationTable() {
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "small")?.points, 46)
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "medium")?.points, 54)
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "large")?.points, 62)
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "extraLarge")?.points, 70)
        XCTAssertNil(DockPanelHeight.migratingLegacyTier(rawValue: "gigantic"))
    }

    func testEveryHeightKeepsIntegerPointsAndDerivedWindowHeight() {
        for height in sampleHeights {
            let m = height.metrics
            XCTAssertEqual(m.panelHeight, height.points)
            XCTAssertEqual(m.panelHeight.rounded(), m.panelHeight, "条高必须是整数，否则圆角和图标落在半像素上")
            XCTAssertEqual(m.windowHeight, m.panelHeight + 2 * m.shadowPadding)
            XCTAssertEqual(m.shadowPadding, 20, "阴影边距不随条高缩放——阴影 token 是冻结的")
        }
    }

    func testNativeHeightMatchesTheNativeDockBaseline() {
        XCTAssertEqual(DockPanelHeight.native.points, 54)
        XCTAssertEqual(DockPanelHeight.native.scale, 1.0)
        XCTAssertEqual(DockPanelHeight.default, DockPanelHeight.native)
        XCTAssertEqual(DockPanelHeight.native.metrics, PanelLayoutMetrics(
            panelHeight: 54, shadowPadding: 20, windowHeight: 94,
            bottomGap: 8, outerMargin: 12,
            minimumDockWidth: 120
        ))
        XCTAssertEqual(PanelLayoutMetrics.properWM, DockPanelHeight.native.metrics)
    }

    func testChipHeightFillsTheNativePanelExactly() {
        XCTAssertEqual(ChipPillMetrics.chipHeight, DockPanelHeight.native.points)
    }

    func testEveryHeightLaysOutBottomAnchoredAndCentered() {
        let screen = screen(frame: CGRect(x: -1512, y: -400, width: 1512, height: 982))
        for height in sampleHeights {
            let metrics = height.metrics
            for contentWidth in [CGFloat(0), 120, 620, 10_000] {
                let frame = PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: screen, metrics: metrics)
                XCTAssertEqual(frame.minY, screen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
                XCTAssertEqual(frame.height, metrics.windowHeight)
                XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 0.01)
            }
        }
    }

    func testFullBarKeepsOuterMarginOnBothSides() {
        let screen = screen(frame: CGRect(x: -1512, y: -400, width: 1512, height: 982))
        for height in sampleHeights {
            let metrics = height.metrics
            let frame = PanelGeometry.dockTargetFrame(contentWidth: 10_000, on: screen, metrics: metrics)
            let visible = frame.insetBy(dx: metrics.shadowPadding, dy: metrics.shadowPadding)
            XCTAssertEqual(visible.minX - screen.frame.minX, metrics.outerMargin, accuracy: 0.01)
            XCTAssertEqual(screen.frame.maxX - visible.maxX, metrics.outerMargin, accuracy: 0.01)
        }
    }

    func testLiftTargetTracksBarHeight() {
        let screenMinY: CGFloat = -400
        let tops = [40, 54, 80].map { DockPanelHeight(clamping: $0).metrics }.map { screenMinY + $0.bottomGap + $0.panelHeight }
        XCTAssertEqual(tops, [-352, -338, -312])
        XCTAssertEqual(tops, tops.sorted(), "抬升目标随条高单调上升")
    }

    private func layout(on screen: PanelScreenGeometry, contentWidth: CGFloat = 620) -> CGRect {
        PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: screen, metrics: metrics)
    }

    private func screen(frame: CGRect, visibleFrame: CGRect? = nil, safeAreaTop: CGFloat = 0) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: frame, visibleFrame: visibleFrame ?? frame, safeAreaTop: safeAreaTop)
    }
}
