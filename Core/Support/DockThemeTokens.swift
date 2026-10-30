import Foundation

// MARK: - 浅 / 深色视觉数值表（纯数据层）
//
// 为什么存在：整套视觉原本是照着**深色模式**手调出来的，全仓库零处按外观分支——所有前景色写死成
// 白、所有阴影写死成黑。浅色模式下 `NSVisualEffectView` 会自己变浅（材质跟随系统），但上面的白字、
// 白描边、白圆点全部失效，黑阴影则变成一圈灰污渍。真实用户报告见 GitHub issue #3 第 3 条：
// 「周围有很明显的方格，然后旁边有阴影，并且还会延伸溢出，整体样式质感不行」——他用的是浅色模式，
// 抱怨的每一点都能对应到下面某个 token 在浅色下的失效。
//
// **本文件不 import SwiftUI**：只存基色 + 不透明度 + 阴影几何，全部是可精确比较的值类型，
// 因此 `DockThemeTests` 能逐项冻结深色列。`Color` / `NSVisualEffectView.Material` 的桥接在
// `App/Scenes/DockTheme.swift`。
//
// Two columns, `light` and `dark`, picked by the window's appearance (`DockTheme.swift`,
// `DockThemeTokens.resolved(for:)`). The light column is the signed-off look and must not drift
// when the dark one is tuned.
//
// ⚠️ 两个「看着像颜色其实不是」的坑，不属于本表、也绝不能按外观改：
//   · `DockStripView` 滚动边缘淡出的 `.black` / `.clear` 是 **mask 的 alpha 通道**，不是颜色。
//   · `PanelCoordinator` 里的 `NSColor(white: 1.0, alpha: 0.0)` 是**全透明**，不是「白色底」。

/// 基色。整套视觉只用纯白 / 纯黑加不透明度叠在毛玻璃上，没有第三种基色
///（唯一的彩色是角标红，它两种模式都成立，不进本表）。
enum DockTintBase: Equatable {
    case white
    case black
}

/// 一个「基色 + 不透明度」的着色值。
struct DockTint: Equatable {
    let base: DockTintBase
    let opacity: Double

    static func white(_ opacity: Double) -> DockTint { .init(base: .white, opacity: opacity) }
    static func black(_ opacity: Double) -> DockTint { .init(base: .black, opacity: opacity) }
}

/// 同一处视觉的常态 / 强调态两个值（强调 = 悬停，或投放命中）。
struct DockTintPair: Equatable {
    let normal: DockTint
    let emphasized: DockTint
}

/// 阴影：颜色 + 模糊半径 + 向下偏移（x 恒为 0，整套视觉没有横向偏移的阴影）。
struct DockShadow: Equatable {
    let tint: DockTint
    let radius: CGFloat
    let y: CGFloat

    /// 阴影向下延伸的总量。**必须 ≤ `PanelCoordinator.shadowPadding`（20pt）**，否则在面板的
    /// 透明边处被硬切成一道齐口直边——这正是用户说的「阴影还会延伸溢出」。
    /// 深色任务条现值 15 + 8 = 23 就超了 3pt；深色冻结，本轮不动它（已单独记待办）。
    /// 浅色列全部收进预算内。
    var verticalExtent: CGFloat { radius + abs(y) }
}

/// 毛玻璃材质。用自己的枚举而不是 `NSVisualEffectView.Material`，是为了让本文件保持不依赖 AppKit
///（映射在 `DockTheme.swift`）。浅色下若觉得底板太白，这里是换材质的出口。
enum DockPanelMaterial: Equatable {
    case popover
    case hudWindow
    case menu
    case underWindowBackground
    case sidebar
    case titlebar
    case selection
    case headerView
    case fullScreenUI
    case toolTip
    case sheet
    case windowBackground
    case contentBackground
    case underPageBackground

    /// 调参用：`DOCK_PANEL_MATERIAL=<名字>` 可以在**不重新构建**的前提下换材质，
    /// 一轮迭代约 8 秒，方便一次拍完整张候选对照表。名字就是上面这些 case（大小写不敏感）。
    /// 认不出的名字**回落到传入的默认值**，绝不崩——调参时手滑打错不该让应用起不来。
    static func resolved(from environment: [String: String], fallback: DockPanelMaterial) -> DockPanelMaterial {
        guard let raw = DebugSwitch.panelMaterial.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return fallback }
        return all.first { "\($0)".lowercased() == raw } ?? fallback
    }

    /// 候选全集，供解析与对照表遍历。系统材质全部 macOS 10.14+，我们最低 12，无需可用性分支。
    static let all: [DockPanelMaterial] = [
        .popover, .hudWindow, .menu, .underWindowBackground, .sidebar,
        .titlebar, .selection, .headerView, .fullScreenUI, .toolTip,
        .sheet, .windowBackground, .contentBackground, .underPageBackground,
    ]
}

// 图标**不再按状态淡化**（owner 2026-08-02 拿掉，浅深两色一起）。状态信号只剩两处：
// 图标下方的运行点（是否运行）、带标题卡片的 `labelActive` / `labelInactive`（是否在桌面）。
// 理由与旧数值见 `Docs/27-product-decisions.md`。

/// A title pill made of the system's regular glass (Liquid Glass path only): its edge light is
/// what gives the card thickness. `tint` pulls the glass toward the side opposite the text, the
/// same rule as `chipPillFill`; `hoverLift` is laid over it as the hover emphasis.
struct DockChipPillGlass: Equatable {
    let tint: DockTint
    let hoverLift: DockTint
}

/// How the hover bubble's surface is built when Liquid Glass is available.
enum DockTooltipSurface: Equatable {
    /// Our near-white plate over clear glass, with our own rim and shadow (`tooltipPlate`).
    case plateOverClearGlass
    /// The system's regular glass and nothing else — no plate, rim or shadow of ours.
    case regularGlassAlone
}

/// 与外观无关的形状常量。原先 `cornerRadius: 16` 在 `DockStripView` 的 private `Style` 里，
/// 导致 `DrawerView` / `FolderGridPopupView` / `ShelfGridPopupView` 各自硬写一遍 16。
enum DockShape {
    /// 所有悬浮面板（任务条 / 抽屉 / 胶囊 / 两个弹窗）的圆角。
    static let panelCornerRadius: CGFloat = 16
}

/// 中转格图标的实心配色。
///
/// **不能用 `DockTint`**：那个只有黑 / 白两种基色，而这块要的是一张「看起来像原生应用图标」
/// 的彩色瓷砖。三档候选放在这里而不是主题表里——它们是同一个位置的互斥选项，不是三个独立数值。
enum DockShelfTileStyle: String, CaseIterable {
    /// 深色收纳袋 + 露出上沿的白纸，矢量自绘（`ShelfTrayArt`）。owner 2026-08-16 指定的样子。
    case tray
    /// 石墨渐变 + 白托盘符号。tray 画得不像时的退路（owner 说的「先用石墨灰」）。
    case graphite
    /// 系统蓝渐变 + 白符号。像一枚第一方工具图标，和右边的文件夹区同色系。
    case blue
    /// 近白渐变 + 深灰符号。最不抢眼，浅色壁纸下靠符号和投影立住。
    case light

    static func resolve(_ raw: String?) -> DockShelfTileStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let style = DockShelfTileStyle(rawValue: raw) else { return .tray }
        return style
    }

    /// 是不是那张自绘插画（`tray`）。其余三档都是「纯色瓷砖 + SF 符号」。
    var isIllustration: Bool { self == .tray }

    /// (上, 下) 渐变端点与符号色，全部是不透明 RGB。`tray` 不走这条路，返回它自己的近似色
    /// 只为让「符号与底对比够」这类不变量对四档统一成立。
    var colors: (top: DockRGB, bottom: DockRGB, glyph: DockRGB) {
        switch self {
        case .tray:
            return (DockRGB(0.30, 0.30, 0.30), DockRGB(0.19, 0.19, 0.19), DockRGB(0.97, 0.97, 0.97))
        case .graphite:
            return (DockRGB(0.45, 0.47, 0.51), DockRGB(0.27, 0.29, 0.33), DockRGB(1, 1, 1))
        case .blue:
            return (DockRGB(0.36, 0.66, 0.98), DockRGB(0.13, 0.45, 0.90), DockRGB(1, 1, 1))
        case .light:
            return (DockRGB(0.99, 0.99, 1.00), DockRGB(0.88, 0.89, 0.92), DockRGB(0.26, 0.28, 0.32))
        }
    }

    /// 投放命中时整块提亮（原来是"底板加浓"，实心块上要反过来）。
    static let dropTargetLift: Double = 0.12
}

/// 不透明 RGB。故意最小化——只有中转格瓷砖用得到，别拿它去替代 `DockTint`。
struct DockRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 朝白色插值，用于投放命中的提亮。
    func lightened(by amount: Double) -> DockRGB {
        let t = min(max(amount, 0), 1)
        return DockRGB(red + (1 - red) * t, green + (1 - green) * t, blue + (1 - blue) * t)
    }

    /// 感知亮度（Rec. 709）。只给单测用，用来断言符号和瓷砖别撞到一起。
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

// MARK: - Tokens

struct DockThemeTokens: Equatable {

    // MARK: 面板（任务条 / 抽屉 / 抽屉胶囊 / 文件夹弹窗 / 中转弹窗 共用）

    /// 面板描边的**上沿**。苹果原生玻璃是「上沿亮、下沿几乎没有」，模拟来自上方的光；
    /// 改造前是均匀一圈白 0.15，浅色下就变成用户说的那圈「明显的方格」灰框。
    /// 深色两端同值（0.15 / 0.15）→ 渐变退化成均匀色，与改造前逐像素一致。
    let panelRimTop: DockTint
    /// 面板描边的**下沿 / 两侧**。
    let panelRimBottom: DockTint
    /// 投放命中时的整框高亮（抽屉图标拖到任务条上方、外部目录悬停文件夹区）。
    let panelRimHighlighted: DockTint
    let panelRimLineWidth: CGFloat
    let panelRimHighlightedLineWidth: CGFloat

    // MARK: 玻璃厚度感（内高光 + 内阴影）
    //
    // 真玻璃的「厚」来自边缘两道信号：上内沿一条亮线（光从上方进入介质）+ 下内沿一道暗收
    // （介质底部的自阴影）。这两层画在材质**之上**、内容**之下**，是我们自己的像素，
    // 因此不受「拿不到窗口背后像素」那条限制——折射和背景饱和度做不到，厚度感能做。
    //
    // **深色一律 opacity 0 + width 0**，渲染上等价于不画，深色继续逐像素冻结。

    let panelInnerHighlight: DockTint
    let panelInnerHighlightWidth: CGFloat
    let panelInnerHighlightBlur: CGFloat
    let panelInnerShadow: DockTint
    let panelInnerShadowWidth: CGFloat
    let panelInnerShadowBlur: CGFloat

    /// 背景饱和度倍数。**1.0 = 不加滤镜**（此时整个修饰符都不挂，同厚度层的理由）。
    ///
    /// 2026-07-30 实测：SwiftUI 的 `.saturation()` 作用在毛玻璃的**合成结果**上（材质 + 已模糊
    /// 的背景），所以能真的把背景颜色提浓，而且**模糊保留**——彩色靶实测条内饱和度
    /// 0.221 → 0.534，条外对照 0.398 不变。
    ///
    /// 对比之下 `.opacity()` 是**死路**，别再试：它把材质本身抹掉一部分、露出**没模糊过**的
    /// 原始桌面（实测条内过渡带从 115px 塌成 0.9px，和条外一样锐利），观感廉价，
    /// 不是"更透的玻璃"而是"挖了个洞的玻璃"。通透度只能靠换材质。
    let panelBackdropSaturation: Double
    /// 任务条 + 抽屉胶囊的落地阴影。
    let stripShadow: DockShadow
    /// 抽屉 + 两个弹窗的落地阴影（比任务条略收，因为它们悬在更高处）。
    let popupShadow: DockShadow
    let panelMaterial: DockPanelMaterial

    // MARK: 多窗口 chip 的标题胶囊

    /// 卡片底。
    ///
    /// **方向必须和文字相反。** 底板是透的、亮度跟着**壁纸**走，而文字颜色是固定的黑；
    /// 两者同向就等于把对比度抹平。2026-08-16 之前这里是「加黑 0.05」——当年为了
    /// 「让卡看起来像张卡」调的，不是为了读得清，正好同向。**别按那个直觉改回加黑。**
    ///
    /// ⚠️ **提亮这里救不了 `labelInactive` 那档灰字，两个值必须成对调。**
    /// 半透明黑字画在药丸上，字的亮度 = 药丸亮度 ×(1−α)，药丸一亮字跟着一起亮：
    /// 灰字 α=0.45 时，底板 110 → 对比 2.13，药丸提到 145 才 2.57、提到 180 也只有 2.82；
    /// 同一底板把灰字自己从 0.45 加深到 0.62 一步就到 2.8+。提亮药丸主要赚的是
    /// `labelActive`（黑 0.85 几乎不透，底板亮多少它就赚多少）。
    ///
    /// 现值 0.24 是 2026-08-28「深色壁纸下看不清」那轮定的，owner 当天实机签收
    ///（此前 0.13，是 owner 2026-08-16 从 0.10 / 0.12 / 0.13 里挑的，只在浅色壁纸上比过）。
    /// 悬停档保持 ×1.4 的既有关系。调参出口：`DOCK_CHIP_PILL_FILL`。
    ///
    /// 卡片的「像张卡」由 `chipPillRimTop` 那圈描边承担，不靠填充——所以描边必须比填充亮。
    let chipPillFill: DockTintPair
    let chipPillRimTop: DockTintPair
    let chipPillRimBottom: DockTint
    /// Non-nil = the pill is system glass where Liquid Glass is available, and `chipPillFill` +
    /// rim are only the fallback (frosted path, drag-carrier bitmap). `nil` = always the flat pill.
    let chipPillGlass: DockChipPillGlass?

    // MARK: 文字

    /// 窗口标题（该窗口在桌面上可见时）。
    let labelActive: DockTint
    /// 窗口标题（已最小化 / 隐藏时）。
    ///
    /// 它是整条上对比度最脆的一处：半透明黑字，底板亮度跟壁纸走。深色壁纸下 0.45 会直接化掉
    /// （owner 2026-08-28 报），而**提亮药丸救不了它**——原因见 `chipPillFill` 的注释。
    /// 现值 0.62，owner 2026-08-28 实机签收。再加深就开始吃掉「在不在当前桌面」这个深浅区分，
    /// 别越过 `labelActive` 0.85。
    /// 调参出口：`DOCK_LABEL_INACTIVE`。
    let labelInactive: DockTint
    /// 标题胶囊下方的应用名副标题。
    let labelSubtitle: DockTint

    // MARK: 指示器

    /// 图标底下的运行小圆点。浅色下白点在浅玻璃上完全看不见。
    let runningDot: DockTint
    /// 任务条分区之间的竖分隔线。
    let zoneDivider: DockTint

    // MARK: 中转格

    /// 中转格瓷砖的配色。**必须不透明**——它是条上唯一一个不是应用图标的 chip，
    /// 半透明的话玻璃底下一暗就消失（owner 2026-08-16 报过）。见 `ShelfChip.shelfIcon`。
    /// 用 `DOCK_SHELF_TILE=blue|graphite|light` 现场换档，不用重编译。
    let shelfTile: DockShelfTileStyle
    /// 投放命中时底板外扩的光晕。
    let shelfDropGlow: DockTint

    // MARK: 抽屉胶囊

    /// 抽屉为空时的四宫格占位符号。
    let capsuleGlyph: DockTint
    /// 拖卡悬到胶囊上的「微微发光」（去掉过生硬白圈后的替代反馈，owner 2026-06-21）。
    let capsuleStashGlow: DockTint

    // MARK: 固定文件夹 chip

    /// 外部文件拖到文件夹 chip 上（= 移入该文件夹）的命中环。
    let folderDropRing: DockTint
    /// 真缩略图封面的细描边（图标封面不描边）。
    let folderThumbHairline: DockTint

    // MARK: Folder / shelf / Trash popup

    // Native readings, not taste. macOS 27's stack grid follows the appearance: light glass with
    // near-black text in light mode, dark glass with white text in dark mode. The drawer forces the
    // dark column whatever the appearance (`StackPopupAppearance.alwaysDark`).
    /// Title and cell names.
    let stackPopupText: DockTint
    /// The status line (empty shelf, Trash state, unreadable folder).
    let stackPopupNote: DockTint
    /// 「Open in Finder」 ring. Dark: composited plus-lighter, the native glyph reads backdrop + 124.
    /// Light: composited plus-darker, black 0.5 takes 127 off the backdrop (native (18,69,101) on
    /// (145,196,228)).
    let stackPopupGlyph: DockTint
    /// Back-button plate when the Dock's own art cannot be loaded (plus-lighter is not used there).
    let stackPopupBackFill: DockTint
    /// Frosted fallback only — the glass draws its own edge and shadow.
    let stackPopupHairline: DockTint
    /// The drawer's rule under its title row: the system separator's dark value.
    let stackPopupSeparator: DockTint
    let stackPopupShadow: DockShadow

    // MARK: 窗口标题 tooltip

    /// 气泡的底板。**不是 `DockTint`**：白/黑两种基色调不出「近白但不是纯白」。
    ///
    /// 数值是解出来的，不是调出来的。同一颗原生气泡在两种背景上的读数：
    /// 纯黑底 **173**、绿壁纸（约 145）底 **216**。设 `读数 = a·L + (1-a)·背景`：
    /// `173 = a·L`，`216 = 173 + (1-a)·145` → **a = 0.70，L = 246**。
    ///
    /// 也就是说原生是**一块近白的板、透三成**。中间走过一次弯路：只拿到黑底那一个读数时，
    /// 我把 173 当成了它的本色，得出「不透明的中性灰」——方向正好反了。**一个背景解不出
    /// 两个未知数**，以后再量这类半透明面，必须取两种背景。
    let tooltipPlate: DockRGB
    /// 见 `tooltipPlate`：0.70 = 透三成背景。
    let tooltipPlateOpacity: Double
    /// 气泡描边。**必须比填充更亮**——这是玻璃的镜面边，也是「利落」的来源；
    /// 反成暗边等于没有边，气泡会化在背景里（2026-08-17 实测原生剖面）。
    let tooltipRim: DockTint
    let tooltipText: DockTint
    /// Whether the bubble's text is drawn with CoreGraphics font smoothing. Smoothing dilates
    /// light-on-dark glyphs: measured on the same two characters, the native dark label's stems
    /// are 1.15px against 2.07px smoothed and 1.14px unsmoothed.
    let tooltipTextSmoothing: Bool
    let tooltipShadow: DockShadow
    /// Liquid Glass path only; the frosted path always draws the plate, rim and shadow above.
    let tooltipGlassSurface: DockTooltipSurface

    /// 这一套值到底画不画厚度层。**深色必须是 `false`**——不是"画一层全透明的"，而是
    /// 整层根本不进视图树。`.blur(radius: 0)` 在 SwiftUI 里仍可能触发离屏渲染，
    /// 多一层就可能让深色的逐像素比对出现差异，冻结就不再是严格的。
    var drawsPanelThickness: Bool {
        Self.drawsThickness(highlight: panelInnerHighlight, highlightWidth: panelInnerHighlightWidth,
                            shadow: panelInnerShadow, shadowWidth: panelInnerShadowWidth)
    }

    /// 上面那条判断的纯函数形式（单测直接打这个，不用为了试 4 个值去构造整张 44 字段的表）。
    /// 颜色透明**或**线宽为 0 都等于看不见，两个条件必须同时满足才算"要画"。
    static func drawsThickness(highlight: DockTint, highlightWidth: CGFloat,
                               shadow: DockTint, shadowWidth: CGFloat) -> Bool {
        (highlight.opacity > 0 && highlightWidth > 0) || (shadow.opacity > 0 && shadowWidth > 0)
    }
}

// MARK: - The two columns

extension DockThemeTokens {
    /// The light column. Text and material must flip together: `NSVisualEffectView` and Liquid
    /// Glass follow the **window's** `effectiveAppearance`, and so does SwiftUI's `colorScheme`,
    /// which is what `resolved(for:)` keys on — never pick a column from anything else.
    static let light = DockThemeTokens(
        panelRimTop: .white(0.6),
        panelRimBottom: .black(0.1),
        // 投放高亮：叠在平时那圈边**之上**的一圈更亮的边（`DockPanelRimPlan`）。
        // 2026-08-20 从黑 0.35 改成白 0.45——黑色那版是玻璃转正前留下的，叠在玻璃的白色
        // 镜面亮边上会变成「一圈黑框」。白 0.45 正是被删掉的深色表当年用的值。
        panelRimHighlighted: .white(0.45),
        panelRimLineWidth: 0.5,
        panelRimHighlightedLineWidth: 1,
        // ⚠️ 下面两组是**候选值，默认不生效**——owner 还没验收，按「未验收一律 opt-in」
        // 的规矩由环境变量开（`DOCK_PANEL_THICKNESS=1` / `DOCK_PANEL_SATURATION=candidate`，
        // 见 `DockEffectSwitches`）。数值留在表里是为了调参时只有一张表可改。
        //
        // 厚度感候选：上内沿一条亮线 + 下内沿一道暗收。
        panelInnerHighlight: .white(0.5),
        panelInnerHighlightWidth: 1.5,
        panelInnerHighlightBlur: 2,
        panelInnerShadow: .black(0.06),
        panelInnerShadowWidth: 2,
        panelInnerShadowBlur: 3,
        // 背景提饱和候选。3.0 是实验用的极端值，日常这个量级即可。
        panelBackdropSaturation: 1.25,
        stripShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        popupShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        // 通透度候选待 owner 从对照表里指定；在那之前保持 .popover。
        panelMaterial: .popover,

        // owner 2026-08-16 实机比过 0.10 / 0.12 / 0.13，定 0.13。悬停态 ×1.4。
        chipPillFill: DockTintPair(normal: .white(0.24), emphasized: .white(0.336)),
        chipPillRimTop: DockTintPair(normal: .white(0.55), emphasized: .white(0.7)),
        chipPillRimBottom: .black(0.1),
        chipPillGlass: nil,

        labelActive: .black(0.85),
        labelInactive: .black(0.62),
        labelSubtitle: .black(0.55),

        runningDot: .black(0.5),
        zoneDivider: .black(0.12),

        shelfTile: .tray,
        shelfDropGlow: .black(0.1),

        capsuleGlyph: .black(0.55),
        capsuleStashGlow: .black(0.1),

        folderDropRing: .black(0.45),
        folderThumbHairline: .black(0.15),

        // Native light: text (22,27,34) on a (150,199,237) plate.
        stackPopupText: .black(0.86),
        stackPopupNote: .black(0.5),
        stackPopupGlyph: .black(0.5),
        stackPopupBackFill: .black(0.08),
        stackPopupHairline: .black(0.12),
        stackPopupSeparator: .black(0.1),
        stackPopupShadow: DockShadow(tint: .black(0.3), radius: 18, y: 6),

        // 2026-08-17 对着原生截图的边缘剖面定的（黑底、@2x）：
        // 原生是「0 → 191 → **209** → 173 173 173…」——一圈**比填充更亮**的 1px 高光，
        // 然后才是填充 173。我们原来是「59 → 157 → 189 → 202」：没有边、填充还偏白，
        // 于是气泡是「化」在背景里的，owner 说的「不利落 / 软」就是这个。
        //
        // 亮边是玻璃的镜面边，和面板描边同一个道理（见 `panelRimTop`），方向不能反。
        // 246/255 = 0.965，透三成——解方程得来的，见 `tooltipPlate` 的注释。
        tooltipPlate: DockRGB(0.965, 0.965, 0.968),
        tooltipPlateOpacity: 0.70,
        // 起始值，待实测标定（见字段注释里的三个目标点）。
        tooltipRim: .white(0.45),
        tooltipText: .black(0.85),
        // The signed-off light bubble; not re-measured against the native one for stem width.
        tooltipTextSmoothing: true,
        tooltipShadow: DockShadow(tint: .black(0.14), radius: 5, y: 2),
        // Regular glass alone was measured and rejected here: it follows the backdrop down to 45
        // on black, where the native light bubble stays 173 (`hover-bubble.md`).
        tooltipGlassSurface: .plateOverClearGlass
    )

    /// The dark column: white marks on the system Dock glass in its dark appearance.
    ///
    /// The plate is the system's (variant 3 under `darkAqua`), so nothing here colours it. It
    /// barely lifts a dark backdrop and dims a bright one — white 255 reads about 176 through it —
    /// which makes the bar over a white window the worst case for white text.
    static let dark = DockThemeTokens(
        // The theme rim is drawn only on the frosted / fallback plate; the system glass has its own.
        panelRimTop: .white(0.15),
        panelRimBottom: .white(0.15),
        panelRimHighlighted: light.panelRimHighlighted,
        panelRimLineWidth: light.panelRimLineWidth,
        panelRimHighlightedLineWidth: light.panelRimHighlightedLineWidth,
        // No thickness or saturation candidates in dark: zero means the layers never enter the tree.
        panelInnerHighlight: .white(0),
        panelInnerHighlightWidth: 0,
        panelInnerHighlightBlur: 0,
        panelInnerShadow: .black(0),
        panelInnerShadowWidth: 0,
        panelInnerShadowBlur: 0,
        panelBackdropSaturation: 1.0,
        stripShadow: DockShadow(tint: .black(0.35), radius: 12, y: 5),
        popupShadow: DockShadow(tint: .black(0.35), radius: 12, y: 5),
        panelMaterial: .popover,

        // Against the text, as in the light column: white text needs a darker pill. Worst case
        // (plate 176): 3.44 active / 2.37 inactive, at or above the light column's own worst case.
        // The pill and `labelInactive` are one pair — tune both, then re-run the contrast test.
        // A lightening pill (white 0.10) was compared and dropped: 1.9 / 1.5 over a white window.
        chipPillFill: DockTintPair(normal: .black(0.25), emphasized: .black(0.33)),
        chipPillRimTop: DockTintPair(normal: .white(0.22), emphasized: .white(0.34)),
        chipPillRimBottom: .white(0.04),
        // Measured through the real materials (dark Dock plate under the pill): over a white
        // backdrop the pill reads 111 — 2.9 inactive / 4.5 active, better than the flat pill —
        // and over blue or black it sits at the plate's level, so the edge light carries the card.
        chipPillGlass: DockChipPillGlass(tint: .black(0.3), hoverLift: .white(0.07)),

        labelActive: .white(0.92),
        labelInactive: .white(0.6),
        labelSubtitle: .white(0.6),

        // The native dot is the plate plus ~124 per channel (additive). Chips sit under the
        // strip's edge-fade mask, where a plus-lighter blend cannot see the glass, so this is
        // the translucent white that lands on the same value over a typical dark plate (36).
        runningDot: .white(0.57),
        zoneDivider: .white(0.18),

        shelfTile: light.shelfTile,
        shelfDropGlow: .white(0.25),

        capsuleGlyph: .white(0.6),
        capsuleStashGlow: .white(0.18),

        folderDropRing: .white(0.9),
        folderThumbHairline: .white(0.3),

        stackPopupText: .white(0.95),
        stackPopupNote: .white(0.6),
        stackPopupGlyph: .white(124.0 / 255.0),
        stackPopupBackFill: .white(60.0 / 255.0),
        stackPopupHairline: .white(0.18),
        stackPopupSeparator: .white(0.1),
        stackPopupShadow: light.stackPopupShadow,

        // The native dark bubble *is* the system's regular glass in its dark appearance: fill
        // 64 over a 35 backdrop and 172 over 219, and the same edge profile and shadow, row for
        // row. So the glass path draws that material and nothing of ours on top.
        // The plate below is the frosted path's stand-in, solved from those two readings
        // (grey 105 at 0.41); it matches them but not a coloured backdrop, which it greys out.
        tooltipPlate: DockRGB(105.0 / 255.0, 105.0 / 255.0, 105.0 / 255.0),
        tooltipPlateOpacity: 0.41,
        tooltipRim: .white(0.12),
        tooltipText: .white(0.96),
        tooltipTextSmoothing: false,
        tooltipShadow: DockShadow(tint: .black(0.25), radius: 5, y: 2),
        tooltipGlassSurface: .regularGlassAlone
    )
}
