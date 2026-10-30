import XCTest

final class DockThemeTests: XCTestCase {
    private let theme = DockThemeTokens.light
    private let dark = DockThemeTokens.dark
    private let shadowPadding: CGFloat = 20

    func testForegroundsAreDarkTinted() {
        let mustBeBlack: [(String, DockTint)] = [
            ("labelActive", theme.labelActive),
            ("labelInactive", theme.labelInactive),
            ("labelSubtitle", theme.labelSubtitle),
            ("runningDot", theme.runningDot),
            ("zoneDivider", theme.zoneDivider),
            ("capsuleGlyph", theme.capsuleGlyph),
            ("folderDropRing", theme.folderDropRing),
            ("tooltipText", theme.tooltipText),
        ]
        for (name, tint) in mustBeBlack {
            XCTAssertEqual(tint.base, .black, "\(name) 必须加黑，加白在浅玻璃上会消失")
        }
    }

    func testShelfTileIsAnOpaqueColouredTile() {
        for style in DockShelfTileStyle.allCases {
            let c = style.colors
            XCTAssertNotEqual(c.top, c.bottom, "\(style) 要有渐变，纯平色不像一枚真图标")
            let tileLuma = (c.top.luminance + c.bottom.luminance) / 2
            XCTAssertGreaterThan(abs(c.glyph.luminance - tileLuma), 0.3,
                                 "\(style) 的符号和瓷砖对比不够")
        }
    }

    func testShelfTileDropTargetLifts() {
        XCTAssertGreaterThan(DockShelfTileStyle.dropTargetLift, 0)
        let base = DockShelfTileStyle.blue.colors.top
        XCTAssertGreaterThan(base.lightened(by: DockShelfTileStyle.dropTargetLift).luminance,
                             base.luminance)
    }

    func testShelfTileStyleFallsBackToDefault() {
        for bad in ["", " ", "purple", "1"] {
            XCTAssertEqual(DockShelfTileStyle.resolve(bad), .tray, "非法值 \(bad) 要回落")
        }
        XCTAssertEqual(DockShelfTileStyle.resolve(" GRAPHITE "), .graphite)
        XCTAssertEqual(theme.effectiveShelfTile, theme.shelfTile,
                       "测试进程没设环境变量，生效值必须是表里的值")
    }

    func testPanelRimIsBrightTopDarkBottom() {
        XCTAssertEqual(theme.panelRimTop.base, .white)
        XCTAssertEqual(theme.panelRimBottom.base, .black)
        XCTAssertGreaterThan(theme.panelRimTop.opacity, theme.panelRimBottom.opacity)
    }

    func testTooltipPlateMatchesTheMeasuredNativeBubble() {
        func composite(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 0), 173, accuracy: 6, "黑底实测 173")
        XCTAssertEqual(composite(over: 145), 216, accuracy: 6, "绿壁纸底实测 216")
        XCTAssertEqual(composite(over: 235), 247, accuracy: 6, "浅色窗口底实测 247（2026-08-17 新增第三点）")
        XCTAssertLessThan(theme.tooltipPlateOpacity, 0.85)
    }

    func testTooltipRimIsBrighterThanItsFill() {
        XCTAssertEqual(theme.tooltipRim.base, .white, "暗边等于没有边")
        func fill(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        func rim(over background: Double) -> Double {
            let f = fill(over: background)
            return f + theme.tooltipRim.opacity * (255 - f)
        }
        XCTAssertEqual(rim(over: 0), 209, accuracy: 6)
        XCTAssertEqual(rim(over: 145), 235, accuracy: 6)
        XCTAssertGreaterThan(rim(over: 0) - fill(over: 0), 20)
        XCTAssertGreaterThan(rim(over: 145) - fill(over: 145), 12)
    }

    func testChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(theme.labelActive.base, .black, "前提：文字是黑的")
        XCTAssertEqual(theme.chipPillFill.normal.base, .white, "方向反了——药丸要把底板推离黑字")
        XCTAssertEqual(theme.chipPillFill.emphasized.base, .white)
        XCTAssertGreaterThan(theme.chipPillFill.emphasized.opacity, theme.chipPillFill.normal.opacity,
                             "悬停态要比常态更浓")
    }

    func testChipPillRimStaysBrighterThanTheFill() {
        XCTAssertEqual(theme.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(theme.chipPillRimTop.normal.opacity, theme.chipPillFill.normal.opacity,
                             "常态：描边要亮于填充")
        XCTAssertGreaterThan(theme.chipPillRimTop.emphasized.opacity, theme.chipPillFill.emphasized.opacity,
                             "悬停态：描边要亮于填充")
    }

    func testInactiveLabelStaysReadableOnADarkBackdrop() {
        XCTAssertGreaterThanOrEqual(theme.labelInactive.opacity, 0.55,
                                    "灰字太淡，深色壁纸下会化掉——提亮药丸补不回来")
        XCTAssertLessThan(theme.labelInactive.opacity, theme.labelActive.opacity,
                          "还得比在桌面那档淡，「在不在当前桌面」全靠这个深浅差")
    }

    func testShadowsFitInsideShadowPaddingBudget() {
        for column in [theme, dark] {
            XCTAssertLessThanOrEqual(column.stripShadow.verticalExtent, shadowPadding)
            XCTAssertLessThanOrEqual(column.popupShadow.verticalExtent, shadowPadding)
        }
    }

    func testStackPopupForegroundsContrastWithTheirPlate() {
        for (column, base) in [(theme, DockTintBase.black), (dark, DockTintBase.white)] {
            for tint in [column.stackPopupText, column.stackPopupNote, column.stackPopupGlyph,
                         column.stackPopupBackFill, column.stackPopupHairline, column.stackPopupSeparator] {
                XCTAssertEqual(tint.base, base)
            }
            XCTAssertGreaterThan(column.stackPopupText.opacity, column.stackPopupNote.opacity)
        }
    }

    func testAllOpacitiesAreInRange() {
        for column in [theme, dark] {
            for tint in column.allTints {
                XCTAssertTrue((0 ... 1).contains(tint.opacity), "不透明度越界：\(tint)")
            }
        }
    }

    func testThicknessGateNeedsBothColourAndWidthWithinAPair() {
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0), shadowWidth: 3),
            "两对的颜色都是 0 → 不画")
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 0, shadow: .black(0.1), shadowWidth: 0),
            "两对的线宽都是 0 → 不画")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0.1), shadowWidth: 3),
            "内阴影这一对齐全 → 画")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 3, shadow: .black(0), shadowWidth: 0),
            "内高光这一对齐全 → 画")
    }

    func testAllEffectsAreOffByDefault() {
        let empty: [String: String] = [:]
        XCTAssertEqual(DockEffectSwitches.saturation(from: empty, candidate: 1.25), 1.0,
                       "没设环境变量 → 不提饱和")
        XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: empty), "没设环境变量 → 不画厚度层")
        XCTAssertEqual(DockPanelMaterial.resolved(from: empty, fallback: .popover), .popover,
                       "没设环境变量 → 用 token 里的材质")
    }

    func testSaturationSwitch() {
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": "candidate"], candidate: 1.25), 1.25)
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": " 1.8 "], candidate: 1.25), 1.8)
        for bad in ["", "abc", "0", "-1", "99"] {
            XCTAssertEqual(DockEffectSwitches.saturation(
                from: ["DOCK_PANEL_SATURATION": bad], candidate: 1.25), 1.0, "非法值 \(bad) 要回落")
        }
    }

    func testThicknessSwitch() {
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": "1"]))
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": " 1 "]))
        for bad in ["", "0", "true", "yes"] {
            XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": bad]))
        }
    }

    func testMaterialOverrideParsesKnownNames() {
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": "hudWindow"], fallback: .popover), .hudWindow)
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": " MENU "], fallback: .popover), .menu)
    }

    func testMaterialOverrideFallsBackOnUnknownOrEmpty() {
        for bad in ["", "  ", "notAMaterial"] {
            XCTAssertEqual(DockPanelMaterial.resolved(
                from: ["DOCK_PANEL_MATERIAL": bad], fallback: .popover), .popover, "「\(bad)」要回落")
        }
    }

    func testMaterialAllCoversEveryCase() {
        XCTAssertEqual(DockPanelMaterial.all.count, 14, "系统材质候选共 14 种；新增 case 时同步这里")
    }

    func testContrastOverridesFallBackToTheTable() {
        let pair = DockTintPair(normal: .white(0.24), emphasized: .white(0.336))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(from: [:], candidate: pair), pair)
        XCTAssertEqual(DockEffectSwitches.labelInactive(from: [:], candidate: .black(0.62)), .black(0.62))
        for bad in ["", "  ", "abc", "-0.1", "1.2", "0.2,", "0.2,abc", "0.2,0.3,0.4"] {
            XCTAssertEqual(DockEffectSwitches.chipPillFill(
                from: ["DOCK_CHIP_PILL_FILL": bad], candidate: pair), pair, "非法值「\(bad)」要回落")
            XCTAssertEqual(DockEffectSwitches.labelInactive(
                from: ["DOCK_LABEL_INACTIVE": bad], candidate: .black(0.62)), .black(0.62),
                "非法值「\(bad)」要回落")
        }
    }

    func testChipPillFillOverrideParses() {
        let pair = DockTintPair(normal: .white(0.24), emphasized: .white(0.336))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": " 0.3 "], candidate: pair),
            DockTintPair(normal: .white(0.3), emphasized: .white(0.3 * 1.4)))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.18, 0.4"], candidate: pair),
            DockTintPair(normal: .white(0.18), emphasized: .white(0.4)))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.9"], candidate: pair).emphasized, .white(1))
    }

    func testLabelInactiveOverrideParses() {
        XCTAssertEqual(DockEffectSwitches.labelInactive(
            from: ["DOCK_LABEL_INACTIVE": " 0.55 "], candidate: .black(0.62)), .black(0.55))
    }

    func testContrastOverridesCannotFlipTheDirection() {
        for column in [theme, dark] {
            let pair = DockEffectSwitches.chipPillFill(
                from: ["DOCK_CHIP_PILL_FILL": "0.3"], candidate: column.chipPillFill)
            XCTAssertEqual(pair.normal, DockTint(base: column.chipPillFill.normal.base, opacity: 0.3))
            XCTAssertEqual(pair.emphasized.base, column.chipPillFill.emphasized.base)
            XCTAssertEqual(
                DockEffectSwitches.labelInactive(from: ["DOCK_LABEL_INACTIVE": "0.5"], candidate: column.labelInactive),
                DockTint(base: column.labelInactive.base, opacity: 0.5))
        }
    }

    func testDarkForegroundsAreWhiteTinted() {
        let mustBeWhite: [(String, DockTint)] = [
            ("labelActive", dark.labelActive),
            ("labelInactive", dark.labelInactive),
            ("labelSubtitle", dark.labelSubtitle),
            ("runningDot", dark.runningDot),
            ("zoneDivider", dark.zoneDivider),
            ("capsuleGlyph", dark.capsuleGlyph),
            ("folderDropRing", dark.folderDropRing),
            ("tooltipText", dark.tooltipText),
        ]
        for (name, tint) in mustBeWhite {
            XCTAssertEqual(tint.base, .white, "\(name) must be white-based in the dark column")
        }
        XCTAssertLessThan(dark.labelInactive.opacity, dark.labelActive.opacity,
                          "the active / inactive difference is the only on-desktop cue")
    }

    func testStackPopupDarkColumnKeepsItsValues() {
        XCTAssertEqual(dark.stackPopupText, .white(0.95))
        XCTAssertEqual(dark.stackPopupNote, .white(0.6))
        XCTAssertEqual(dark.stackPopupGlyph, .white(124.0 / 255.0))
        XCTAssertEqual(dark.stackPopupBackFill, .white(60.0 / 255.0))
        XCTAssertEqual(dark.stackPopupHairline, .white(0.18))
        XCTAssertEqual(dark.stackPopupSeparator, .white(0.1))
        XCTAssertEqual(dark.stackPopupShadow, theme.stackPopupShadow)
        XCTAssertEqual(dark.shelfTile, theme.shelfTile, "the shelf tile is opaque art, not a tint")
    }

    func testDarkChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(dark.labelActive.base, .white, "premise: the text is white")
        XCTAssertEqual(dark.chipPillFill.normal.base, .black)
        XCTAssertEqual(dark.chipPillFill.emphasized.base, .black)
        XCTAssertGreaterThan(dark.chipPillFill.emphasized.opacity, dark.chipPillFill.normal.opacity)
        XCTAssertEqual(dark.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(dark.chipPillRimTop.emphasized.opacity, dark.chipPillRimTop.normal.opacity)
    }

    func testTitlesKeepTheContrastFloorOnEachColumnsWorstBackdrop() {
        let activeFloor = 2.8, inactiveFloor = 2.3
        let cases: [(String, DockThemeTokens, Double)] = [("light", theme, 38), ("dark", dark, 176)]
        for (name, column, plate) in cases {
            for (state, pill) in [("normal", column.chipPillFill.normal), ("hover", column.chipPillFill.emphasized)] {
                let pillLevel = Self.composite(pill, over: plate)
                let active = Self.contrast(Self.composite(column.labelActive, over: pillLevel), pillLevel)
                let inactive = Self.contrast(Self.composite(column.labelInactive, over: pillLevel), pillLevel)
                XCTAssertGreaterThanOrEqual(active, activeFloor, "\(name) \(state): active title \(active)")
                XCTAssertGreaterThanOrEqual(inactive, inactiveFloor, "\(name) \(state): inactive title \(inactive)")
            }
        }
    }

    func testDarkTooltipIsSystemGlassWithAPlateFittedForTheFrostedPath() {
        XCTAssertEqual(dark.tooltipGlassSurface, .regularGlassAlone)
        XCTAssertEqual(theme.tooltipGlassSurface, .plateOverClearGlass,
                       "light: regular glass alone falls to 45 on black, the native bubble stays 173")
        func composite(over background: Double) -> Double {
            dark.tooltipPlateOpacity * dark.tooltipPlate.luminance * 255
                + (1 - dark.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 35), 64, accuracy: 4)
        XCTAssertEqual(composite(over: 219), 172, accuracy: 4)
        XCTAssertEqual(dark.tooltipRim.base, .white, "a dark rim is no rim")
    }

    func testDarkColumnCarriesNoEffectCandidates() {
        XCTAssertFalse(dark.drawsPanelThickness)
        XCTAssertEqual(dark.panelBackdropSaturation, 1.0)
    }

    func testResolvedColumnFollowsTheColourScheme() {
        XCTAssertEqual(DockThemeTokens.resolved(for: .light), .light)
        XCTAssertEqual(DockThemeTokens.resolved(for: .dark), .dark)
    }

    func testGlassPillKeepsTheFlatPillsDirection() throws {
        let glass = try XCTUnwrap(dark.chipPillGlass)
        XCTAssertEqual(glass.tint.base, .black)
        XCTAssertEqual(dark.chipPillFill.normal.base, .black, "the fallback under the glass candidate")
        XCTAssertNil(theme.chipPillGlass, "the light pill is signed off as the flat one")
    }

    private static func composite(_ tint: DockTint, over background: Double) -> Double {
        let base: Double = tint.base == .white ? 255 : 0
        return background * (1 - tint.opacity) + base * tint.opacity
    }

    private static func relativeLuminance(_ level: Double) -> Double {
        let c = level / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

private extension DockThemeTokens {
    var allTints: [DockTint] {
        [panelRimTop, panelRimBottom, panelRimHighlighted,
         panelInnerHighlight, panelInnerShadow,
         stripShadow.tint, popupShadow.tint,
         chipPillFill.normal, chipPillFill.emphasized,
         chipPillRimTop.normal, chipPillRimTop.emphasized, chipPillRimBottom,
         labelActive, labelInactive, labelSubtitle,
         runningDot, zoneDivider,
         shelfDropGlow,
         capsuleGlyph, capsuleStashGlow,
         folderDropRing, folderThumbHairline,
         stackPopupText, stackPopupNote, stackPopupGlyph, stackPopupBackFill,
         stackPopupHairline, stackPopupSeparator, stackPopupShadow.tint,
         tooltipRim, tooltipText, tooltipShadow.tint]
    }
}
