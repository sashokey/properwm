import XCTest

/// The table has two columns, `light` and `dark`. These tests lock invariants tied to function —
/// foreground direction, the pill pushing the plate away from the text, a contrast floor on each
/// column's worst backdrop, shadows inside their budget, effects off by default — not individual
/// numbers, which are look and stay free to tune.
final class DockThemeTests: XCTestCase {
    /// The light column; the tests below that say nothing else are about it.
    private let theme = DockThemeTokens.light
    private let dark = DockThemeTokens.dark
    private let shadowPadding: CGFloat = 20

    // MARK: - 前景方向

    /// 前景必须是**加黑**而不是加白：浅色玻璃上加白等于消失，只剩描边孤零零留着，
    /// 每张卡就变成一个空心方格——这正是用户抱怨过的「周围有很明显的方格」。
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

    /// 中转格是条上唯一一个**不是应用图标**的 chip。它必须是**不透明的实心瓷砖**：
    /// 半透明的话玻璃底下一暗就消失（owner 2026-08-16 报过），所以它的配色走 `DockRGB`
    /// 而不是只有黑白两种基色的 `DockTint`——这条断言就是防止有人把它改回半透明染色。
    func testShelfTileIsAnOpaqueColouredTile() {
        for style in DockShelfTileStyle.allCases {
            let c = style.colors
            XCTAssertNotEqual(c.top, c.bottom, "\(style) 要有渐变，纯平色不像一枚真图标")
            // 符号与瓷砖必须分处明暗两端，否则符号在自己的底上消失。
            let tileLuma = (c.top.luminance + c.bottom.luminance) / 2
            XCTAssertGreaterThan(abs(c.glyph.luminance - tileLuma), 0.3,
                                 "\(style) 的符号和瓷砖对比不够")
        }
    }

    /// 投放命中是**整块提亮**（实心瓷砖上「加浓」没有意义）。
    func testShelfTileDropTargetLifts() {
        XCTAssertGreaterThan(DockShelfTileStyle.dropTargetLift, 0)
        let base = DockShelfTileStyle.blue.colors.top
        XCTAssertGreaterThan(base.lightened(by: DockShelfTileStyle.dropTargetLift).luminance,
                             base.luminance)
    }

    /// 认不出的名字回落到默认档，别崩也别黑屏。
    func testShelfTileStyleFallsBackToDefault() {
        for bad in ["", " ", "purple", "1"] {
            XCTAssertEqual(DockShelfTileStyle.resolve(bad), .tray, "非法值 \(bad) 要回落")
        }
        XCTAssertEqual(DockShelfTileStyle.resolve(" GRAPHITE "), .graphite)
        XCTAssertEqual(theme.effectiveShelfTile, theme.shelfTile,
                       "测试进程没设环境变量，生效值必须是表里的值")
    }

    /// 面板描边是「上沿亮（白高光）+ 下沿暗（黑细线）」——苹果原生玻璃的打光方向。
    /// 均匀一圈白描边在浅底板上就是用户看到的那种灰框。
    func testPanelRimIsBrightTopDarkBottom() {
        XCTAssertEqual(theme.panelRimTop.base, .white)
        XCTAssertEqual(theme.panelRimBottom.base, .black)
        XCTAssertGreaterThan(theme.panelRimTop.opacity, theme.panelRimBottom.opacity)
    }

    /// 气泡底板锁的是**合成后的读数**，不是单个数值——这样换写法也不会漂。
    /// 两个锚点来自同一颗原生气泡在两种背景上的实测：纯黑底 173、绿壁纸（145）底 216。
    func testTooltipPlateMatchesTheMeasuredNativeBubble() {
        func composite(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 0), 173, accuracy: 6, "黑底实测 173")
        XCTAssertEqual(composite(over: 145), 216, accuracy: 6, "绿壁纸底实测 216")
        XCTAssertEqual(composite(over: 235), 247, accuracy: 6, "浅色窗口底实测 247（2026-08-17 新增第三点）")
        // 反过来钉住「它是半透的」：完全不透就跟不上背景，浅壁纸下会显得脏。
        XCTAssertLessThan(theme.tooltipPlateOpacity, 0.85)
    }

    /// **气泡描边必须比填充更亮。** 原生剖面（黑底 @2x）是 0 → 191 → 209 → 173：
    /// 一圈比填充还亮的镜面边，气泡靠它从背景里切出来。我们曾经用加黑 0.1，
    /// 等于没有边，观感就是 owner 说的「不利落」。
    func testTooltipRimIsBrighterThanItsFill() {
        XCTAssertEqual(theme.tooltipRim.base, .white, "暗边等于没有边")
        // 描边压在**合成后的填充**上，不是压在底板色上——两者在近白底板下差很多。
        func fill(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        func rim(over background: Double) -> Double {
            let f = fill(over: background)
            return f + theme.tooltipRim.opacity * (255 - f)
        }
        // 原生实测：黑底 209（填充 173）、绿壁纸底 235（填充 216）。
        XCTAssertEqual(rim(over: 0), 209, accuracy: 6)
        XCTAssertEqual(rim(over: 145), 235, accuracy: 6)
        // 两种背景下都必须真的看得见，这才是「利落」的来源。
        XCTAssertGreaterThan(rim(over: 0) - fill(over: 0), 20)
        XCTAssertGreaterThan(rim(over: 145) - fill(over: 145), 12)
    }

    // MARK: - 药丸与光晕：必须把底板推离文字

    /// **药丸的方向必须和文字相反。**
    ///
    /// 底板是透的、亮度跟**壁纸**走，而文字颜色是固定的黑；药丸和文字同向就等于把对比度抹平。
    /// 2026-08-16 之前这里是加黑 0.05——当年为了「让卡看起来像张卡」调的，不是为了读得清，
    /// 正好同向。**别按那个直觉把它改回加黑。** 卡片的「像张卡」由 `chipPillRimTop`
    /// 那圈描边承担，不靠填充。
    func testChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(theme.labelActive.base, .black, "前提：文字是黑的")
        XCTAssertEqual(theme.chipPillFill.normal.base, .white, "方向反了——药丸要把底板推离黑字")
        XCTAssertEqual(theme.chipPillFill.emphasized.base, .white)
        XCTAssertGreaterThan(theme.chipPillFill.emphasized.opacity, theme.chipPillFill.normal.opacity,
                             "悬停态要比常态更浓")
    }

    /// **描边必须比填充亮。** 卡片的「像张卡」靠 `chipPillRimTop` 那圈边，不靠填充；
    /// 2026-08-28 为了深色壁纸下的可读性把填充从 0.13 提到 0.24，再往上提就会把边吃掉，
    /// 卡片退化成一块糊在条上的白板。要继续提填充，得先把描边一起提。
    func testChipPillRimStaysBrighterThanTheFill() {
        XCTAssertEqual(theme.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(theme.chipPillRimTop.normal.opacity, theme.chipPillFill.normal.opacity,
                             "常态：描边要亮于填充")
        XCTAssertGreaterThan(theme.chipPillRimTop.emphasized.opacity, theme.chipPillFill.emphasized.opacity,
                             "悬停态：描边要亮于填充")
    }

    /// **药丸底和「不在桌面」那档文字是一对，别只调其中一个。**
    /// 半透明黑字画在药丸上，字的亮度 = 药丸亮度 ×(1−α)，提亮药丸时字跟着一起亮——
    /// 所以提药丸救的是 `labelActive`（几乎不透），救不了 `labelInactive`。
    /// 这条锁的是「灰字别淡回去」：它必须明显比一半更实，否则深色壁纸下就化掉了
    ///（owner 2026-08-28 报的就是 0.45 那一版）。
    func testInactiveLabelStaysReadableOnADarkBackdrop() {
        XCTAssertGreaterThanOrEqual(theme.labelInactive.opacity, 0.55,
                                    "灰字太淡，深色壁纸下会化掉——提亮药丸补不回来")
        XCTAssertLessThan(theme.labelInactive.opacity, theme.labelActive.opacity,
                          "还得比在桌面那档淡，「在不在当前桌面」全靠这个深浅差")
    }

    // MARK: - 数值合法性

    func testShadowsFitInsideShadowPaddingBudget() {
        for column in [theme, dark] {
            XCTAssertLessThanOrEqual(column.stripShadow.verticalExtent, shadowPadding)
            XCTAssertLessThanOrEqual(column.popupShadow.verticalExtent, shadowPadding)
        }
    }

    /// The stack popup follows the appearance (macOS 27's native stack grid is light glass with dark
    /// text in light mode, dark glass with white text in dark mode): each column's foregrounds are the
    /// opposite of its plate.
    func testStackPopupForegroundsContrastWithTheirPlate() {
        for (column, base) in [(theme, DockTintBase.black), (dark, DockTintBase.white)] {
            for tint in [column.stackPopupText, column.stackPopupNote, column.stackPopupGlyph,
                         column.stackPopupBackFill, column.stackPopupHairline, column.stackPopupSeparator] {
                XCTAssertEqual(tint.base, base)
            }
            XCTAssertGreaterThan(column.stackPopupText.opacity, column.stackPopupNote.opacity)
        }
    }

    /// The frosted fallback's shadow lives in the popup window's own transparent border.
    func testStackPopupShadowFitsInsideItsPanelMargin() {
        XCTAssertLessThanOrEqual(theme.stackPopupShadow.verticalExtent, StackPopupMetrics.panelMargin)
    }

    /// 手调时容易顺手写超。
    func testAllOpacitiesAreInRange() {
        for column in [theme, dark] {
            for tint in column.allTints {
                XCTAssertTrue((0 ... 1).contains(tint.opacity), "不透明度越界：\(tint)")
            }
        }
    }

    /// 厚度层的闸门：**两对（内高光 / 内阴影）里只要有一对「颜色和线宽都非零」就画**。
    /// 判据落在「同一对内部」——颜色 0 或线宽 0 的那一对不算数，否则会画出一层看不见的
    /// 离屏渲染（`.blur(radius: 0)` 一样会触发）。
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

    // MARK: - 效果开关

    /// **未验收的效果一律默认关。** 2026-07-30 栽过一次：玻璃探路正确地做成了默认关，
    /// 同一天落地的提饱和和厚度层却默认开，于是 owner 眼里的条悄悄偏离了他签收过的版本。
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

    // MARK: - 对比度调参出口
    //
    // 这两个和上面的「效果开关」不是一回事：默认值**就是已签收的观感**，环境变量只是不重编译
    // 就能来回切的调参出口（同 `DOCK_DRAG_FLIGHT_MS`）。所以断的是「没设 / 乱填一律回落到表里」，
    // 不是「默认关」。

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
        // 只给一个数 → 悬停态按表里既有的 ×1.4 推出来。
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": " 0.3 "], candidate: pair),
            DockTintPair(normal: .white(0.3), emphasized: .white(0.3 * 1.4)))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.18, 0.4"], candidate: pair),
            DockTintPair(normal: .white(0.18), emphasized: .white(0.4)))
        // ×1.4 推出来的值不许溢出 1.0。
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.9"], candidate: pair).emphasized, .white(1))
    }

    func testLabelInactiveOverrideParses() {
        XCTAssertEqual(DockEffectSwitches.labelInactive(
            from: ["DOCK_LABEL_INACTIVE": " 0.55 "], candidate: .black(0.62)), .black(0.55))
    }

    /// 覆盖值的**基色不给出口**：方向不能靠环境变量翻过来
    ///（翻过来就是把对比度抹平，见 `DockThemeTokens.chipPillFill` 的注释）。
    /// The override changes the opacity only; each column keeps its own base.
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

    // MARK: - Dark column

    /// The mirror of `testForegroundsAreDarkTinted`: on the dark glass, black marks vanish.
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

    /// The dark column is the drawer's (forced dark) and dark mode's: the values it had when the
    /// popup was dark in both appearances, unchanged.
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

    /// Same rule as the light column, mirrored: white text, so the pill darkens the plate.
    func testDarkChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(dark.labelActive.base, .white, "premise: the text is white")
        XCTAssertEqual(dark.chipPillFill.normal.base, .black)
        XCTAssertEqual(dark.chipPillFill.emphasized.base, .black)
        XCTAssertGreaterThan(dark.chipPillFill.emphasized.opacity, dark.chipPillFill.normal.opacity)
        // The card's outline is the rim's job; on a dark backdrop the fill is nearly invisible.
        XCTAssertEqual(dark.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(dark.chipPillRimTop.emphasized.opacity, dark.chipPillRimTop.normal.opacity)
    }

    /// **The contrast floor.** Composite the pill onto the plate, then the *translucent* text onto
    /// the pill, then take the sRGB contrast ratio — leaving the text's own opacity out overstates
    /// it badly. Each column is judged on its worst backdrop, read off the system Dock glass:
    /// light = bar over black (plate 38), dark = bar over white (plate 176). The floor is what
    /// the signed-off light column achieves there, so dark may not read worse than light already does.
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

    /// The dark bubble is the system's regular glass on the glass path (the native one reads the
    /// same, row for row); the plate is only the frosted path's stand-in, solved from the native
    /// bubble on two backdrops: 64 over 35 and 172 over 219.
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

    /// No unaccepted effect rides in with the dark column: zero means the layers never enter the tree.
    func testDarkColumnCarriesNoEffectCandidates() {
        XCTAssertFalse(dark.drawsPanelThickness)
        XCTAssertEqual(dark.panelBackdropSaturation, 1.0)
    }

    func testResolvedColumnFollowsTheColourScheme() {
        XCTAssertEqual(DockThemeTokens.resolved(for: .light), .light)
        XCTAssertEqual(DockThemeTokens.resolved(for: .dark), .dark)
    }

    /// The glass pill is tinted to the side opposite the text, like the flat pill it falls back to
    /// (frosted path, drag-carrier bitmap) — and the light column has no glass pill at all.
    func testGlassPillKeepsTheFlatPillsDirection() throws {
        let glass = try XCTUnwrap(dark.chipPillGlass)
        XCTAssertEqual(glass.tint.base, .black)
        XCTAssertEqual(dark.chipPillFill.normal.base, .black, "the fallback under the glass candidate")
        XCTAssertNil(theme.chipPillGlass, "the light pill is signed off as the flat one")
    }

    // MARK: - Contrast helpers (levels are 0…255)

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
    /// 遍历用：本表里所有着色值（含阴影自带的着色）。新增字段时补进来。
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
