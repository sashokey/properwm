import CoreGraphics

/// 面板描边的**纯决策层**：两层边（玻璃镜面亮边 / 主题描边）在某一刻各自画多宽。
///
/// 存在的理由是一个真实回归（2026-08-20 owner 报「从抽屉往任务条拖图标，整条任务条一圈黑边」）：
/// 当时投放高亮的写法是**把玻璃亮边整个从视图树里拿掉、换成主题描边**。玻璃转正为默认之前
/// 主题描边只是把「白 0.6 → 黑 0.1」的渐变边压深一档，看着不刺眼；玻璃转正之后，平时那圈是
/// 对着原生 Dock 量出来的白色镜面亮边（峰值 0.75），于是同一段代码变成了「亮白边 → 纯黑边」。
///
/// 现在的规则：**玻璃亮边任何时候都画，高亮是叠上去的，不是换掉它。**
enum DockPanelRimPlan {
    /// 玻璃镜面亮边（`DockGlassRim`）画不画。只看走不走玻璃路径，与高亮无关。
    /// The system variant plate draws its own rim; a hand-drawn one on top would double it.
    static func glassRimVisible(usesLiquidGlass: Bool, usesSystemVariant: Bool) -> Bool {
        usesLiquidGlass && !usesSystemVariant
    }

    /// 主题描边的线宽。
    ///
    /// - 毛玻璃路径（macOS 12–25）：它**就是**那圈边，平时和高亮都画。
    /// - 玻璃路径：平时交给 `DockGlassRim`，主题描边宽度 0（不进视图树的等价物）；
    ///   只有高亮时才叠出来。宽度从 0 长到 `lineWidth`，所以那 0.15s 的淡入是靠线宽插值实现的，
    ///   高亮色与平时的渐变之间那次 `AnyShapeStyle` 硬切发生在宽度还是 0 的时候，看不见。
    static func themeStrokeWidth(usesLiquidGlass: Bool,
                                 highlighted: Bool,
                                 lineWidth: CGFloat) -> CGFloat {
        guard usesLiquidGlass else { return lineWidth }
        return highlighted ? lineWidth : 0
    }
}
