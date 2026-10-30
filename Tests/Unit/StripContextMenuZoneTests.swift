import XCTest
@testable import macos_dock_cc_v2

final class StripContextMenuZoneTests: XCTestCase {
    /// 中档基线的一条典型任务条：内缩 20pt，chip 40 宽、间距 2pt，
    /// 第 2、3 个 chip 之间夹一条分割线（多占 9pt，缝宽 13pt）。
    ///
    /// 数字取自真实布局（`ChipPillMetrics.cardWidth` / `Style.chipSpacing`），
    /// 但**这里刻意写成字面值**：这组夹具是给纯函数喂的输入，写成引用就会跟着实现一起变，
    /// 等于没测。改布局常量时手工同步这里，`testThresholdSeparatesBothGapsAtEveryTier`
    /// 会告诉你有没有漏。
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 54)
    private let chips: [CGRect] = [
        CGRect(x: 20, y: 0, width: 40, height: 54),    // 20...60
        CGRect(x: 62, y: 0, width: 40, height: 54),    // 62...102 （与上一个间隔 2pt）
        CGRect(x: 115, y: 0, width: 40, height: 54),   // 115...155（与上一个间隔 13pt：分割线）
    ]
    private let gap = StripContextMenuZone.defaultMinimumGapWidth

    private func claims(x: CGFloat) -> Bool {
        StripContextMenuZone.claims(
            point: CGPoint(x: x, y: 26),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap
        )
    }

    func testLeftInsetClaims() {
        XCTAssertTrue(claims(x: 10))
    }

    func testRightInsetClaims() {
        XCTAssertTrue(claims(x: 250))
    }

    func testDividerGapClaims() {
        // 缝是 102...115，正中 108.5。
        XCTAssertTrue(claims(x: 108))
    }

    /// 这一条是本次改动的**目的**：瞄图标差几 pt 落进窄缝时，宁可没反应，
    /// 也不要弹出钨极菜单顶掉那个 app 自己的菜单。
    func testPlainChipGapDoesNotClaim() {
        // 缝是 60...62，只有 2pt。
        XCTAssertFalse(claims(x: 61))
    }

    func testPointOnAChipDoesNotClaim() {
        XCTAssertFalse(claims(x: 40))
        XCTAssertFalse(claims(x: 82))
    }

    func testPointOutsideBoundsDoesNotClaim() {
        XCTAssertFalse(claims(x: -5))
        XCTAssertFalse(StripContextMenuZone.claims(
            point: CGPoint(x: 100, y: 999),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap
        ))
    }

    /// 首帧还没量到任何 chip 时不认——此刻分不清点在不在图标上，
    /// 抢走那个 app 的菜单比少弹一次更糟。
    func testEmptyFramesDoNotClaim() {
        XCTAssertFalse(StripContextMenuZone.claims(
            point: CGPoint(x: 10, y: 26),
            chipFrames: [],
            bounds: bounds,
            minimumGapWidth: gap
        ))
    }

    /// 两种缝在四个档位下都必须分得开：阈值和几何一起缩放。
    ///
    /// **这条是 `Style.chipSpacing` 的护栏。** 2026-08-16 图标间距对齐原生
    /// （中心间距 52→42pt，chipSpacing 8→2）时，分割线缝从 21pt 缩到 9pt，
    /// 而阈值还停在 12pt —— 那会让分割线那道缝也认不出来，整条任务条右键失效。
    /// 就是这条测试拦下来的。
    func testThresholdSeparatesBothGapsAtEveryTier() {
        for scale in [40, 54, 80].map({ DockPanelHeight(clamping: $0).scale }) {
            let plainGap: CGFloat = 2 * scale
            let dividerGap: CGFloat = StripContextMenuZone.dividerGapWidth * scale
            let threshold: CGFloat = StripContextMenuZone.defaultMinimumGapWidth * scale
            XCTAssertLessThan(plainGap, threshold, "普通缝在 scale=\(scale) 下不该被认")
            XCTAssertGreaterThan(dividerGap, threshold, "分割线缝在 scale=\(scale) 下必须被认")
        }
    }

    /// 帧重叠（消息区外扩过的帧、拖动中的临时位置）不能被算成一道缝。
    func testOverlappingFramesDoNotSynthesizeAGap() {
        let overlapping = [
            CGRect(x: 20, y: 0, width: 40, height: 54),   // 20...60
            CGRect(x: 52, y: 0, width: 40, height: 54),   // 52...92，与上一个重叠
            CGRect(x: 84, y: 0, width: 40, height: 54),   // 84...124，与上一个重叠
        ]
        for x in stride(from: CGFloat(21), to: 123, by: 3) {
            XCTAssertFalse(
                StripContextMenuZone.claims(
                    point: CGPoint(x: x, y: 26),
                    chipFrames: overlapping,
                    bounds: bounds,
                    minimumGapWidth: gap
                ),
                "x=\(x) 落在连续覆盖区里，不该被当成缝"
            )
        }
    }
    /// The fixtures above hard-code the 13pt divider gap; this fails when the layout constant
    /// moves without them.
    func testDividerGapWidthMatchesTheFixtures() {
        XCTAssertEqual(StripContextMenuZone.dividerGapWidth, 13)
        XCTAssertEqual(chips[2].minX - chips[1].maxX, StripContextMenuZone.dividerGapWidth)
    }

    // MARK: - Drag-to-resize grip

    private func gripClaims(x: CGFloat, scale: CGFloat = 1) -> Bool {
        StripContextMenuZone.gripClaims(
            point: CGPoint(x: x, y: 26),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap * scale,
            chipClearance: StripContextMenuZone.defaultGripChipClearance * scale
        )
    }

    /// The divider gap is 102...115; the grip keeps 2.5pt off each chip, leaving 104.5...112.5.
    func testGripClaimsOnlyTheMiddleOfTheDividerGap() {
        XCTAssertTrue(gripClaims(x: 108.5))
        XCTAssertTrue(gripClaims(x: 105))
        XCTAssertTrue(gripClaims(x: 112))
        XCTAssertFalse(gripClaims(x: 103), "next to the left icon")
        XCTAssertFalse(gripClaims(x: 114), "next to the right icon")
        XCTAssertTrue(claims(x: 103), "right-click keeps the full gap")
        XCTAssertTrue(claims(x: 114), "right-click keeps the full gap")
    }

    /// With a divider on the bar the grip lives in its gap alone; right-click keeps the ends.
    func testGripLeavesTheEndInsetsWhenADividerExists() {
        XCTAssertFalse(gripClaims(x: 10))
        XCTAssertFalse(gripClaims(x: 250))
        XCTAssertTrue(claims(x: 10))
        XCTAssertTrue(claims(x: 250))
    }

    /// A single-zone bar has no divider, so the end insets are the only grip — still kept clear
    /// of the end icons.
    func testGripFallsBackToTheEndInsetsWithoutADivider() {
        let singleZone = Array(chips.prefix(2))   // 20...60, 62...102
        func grip(_ x: CGFloat) -> Bool {
            StripContextMenuZone.gripClaims(
                point: CGPoint(x: x, y: 26),
                chipFrames: singleZone,
                bounds: bounds,
                minimumGapWidth: gap,
                chipClearance: StripContextMenuZone.defaultGripChipClearance
            )
        }
        XCTAssertTrue(grip(10))
        XCTAssertFalse(grip(18), "next to the first icon")
        XCTAssertTrue(grip(250))
        XCTAssertFalse(grip(104), "next to the last icon")
        XCTAssertFalse(grip(61), "plain chip gap")
    }

    func testHasDividerGapIgnoresPlainGapsAndOverlaps() {
        XCTAssertTrue(StripContextMenuZone.hasDividerGap(chipFrames: chips, minimumGapWidth: gap))
        XCTAssertFalse(StripContextMenuZone.hasDividerGap(chipFrames: Array(chips.prefix(2)), minimumGapWidth: gap))
        XCTAssertFalse(StripContextMenuZone.hasDividerGap(chipFrames: [], minimumGapWidth: gap))
        let overlapping = [
            CGRect(x: 20, y: 0, width: 80, height: 54),   // 20...100
            CGRect(x: 30, y: 0, width: 40, height: 54),   // 30...70, inside the first
            CGRect(x: 102, y: 0, width: 40, height: 54),  // 2pt after the first, 32pt after the second
        ]
        XCTAssertFalse(StripContextMenuZone.hasDividerGap(chipFrames: overlapping, minimumGapWidth: gap))
    }

    func testGripNeverClaimsWhatRightClickRejects() {
        for x in stride(from: CGFloat(-5), to: 305, by: 0.5) {
            if gripClaims(x: x) { XCTAssertTrue(claims(x: x), "x=\(x)") }
        }
    }

    /// The ▲▼ cursor (9pt, unscaled) at the band's edge must not reach the neighbouring icon's
    /// artwork (~9.75% transparent margin inside the 40pt card), and the band must stay
    /// non-empty, at every height.
    func testGripBandLeavesTheGlyphClearOfIconsAtEveryTier() {
        for scale in [40, 54, 80].map({ DockPanelHeight(clamping: $0).scale }) {
            let dividerGap: CGFloat = StripContextMenuZone.dividerGapWidth * scale
            let clearance = StripContextMenuZone.defaultGripChipClearance * scale
            let bandHalfWidth = dividerGap / 2 - clearance
            XCTAssertGreaterThan(bandHalfWidth, 1, "grip band vanishes at scale=\(scale)")
            let iconArtworkEdge = dividerGap / 2 + 40 * scale * 0.0975
            XCTAssertLessThanOrEqual(bandHalfWidth + 4.5, iconArtworkEdge, "glyph overlaps icons at scale=\(scale)")
        }
    }
}
