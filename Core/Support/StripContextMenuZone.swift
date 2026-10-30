import CoreGraphics
import Foundation

/// 右键任务条底板时，该不该弹钨极菜单的**纯决策层**。
///
/// 只认两块地方（owner 2026-08-03 定）：
/// - **两端空白**：最左 chip 左边、最右 chip 右边的内缩边距；
/// - **区域分割线周围**：分割线所在的那道宽缝。
///
/// 刻意**不认 chip 之间的窄缝**：用户瞄图标差几 pt 落进去时弹出钨极菜单
/// （而不是那个 app 自己的菜单）比什么都不弹更糟。代价是窄缝右键完全没反应，这是已知取舍。
///
/// 两种缝靠宽度分辨：分割线两侧的空当是
/// `2(HStack 间距) + 9(1pt 发丝线 + 左右各 4pt 内边距) + 2(HStack 间距) = 13pt`（`dividerGapWidth`），
/// 普通 chip 间距只有 `2pt`；阈值取两者之间即可，且随档位一起缩放。
///
/// **阈值必须严格落在两者之间，改 `Style.chipSpacing` 就要同步改它。**
/// 2026-08-16 图标间距对齐原生 Dock（中心间距 52→42pt，`chipSpacing` 8→2）时，
/// 分割线缝从 21pt 缩到 9pt，而阈值还是 12pt —— 那会让分割线那道缝也认不出来，
/// 于是整条任务条右键完全失效。
enum StripContextMenuZone {
    /// 中档基线。调用方传 `defaultMinimumGapWidth * scale`。
    /// 5pt：大于普通缝 2pt，小于分割线缝 13pt。
    static let defaultMinimumGapWidth: CGFloat = 5

    /// `point` 与 `chipFrames` 都在 "strip" 坐标空间（左上原点、y 向下）。
    static func claims(
        point: CGPoint,
        chipFrames: [CGRect],
        bounds: CGRect,
        minimumGapWidth: CGFloat
    ) -> Bool {
        guard bounds.contains(point) else { return false }
        // 一个 chip 都还没量到（首帧）时不认：宁可这一次右键没反应，
        // 也不要在"其实点在图标上"的时候抢走那个 app 的菜单。
        guard !chipFrames.isEmpty else { return false }
        guard !chipFrames.contains(where: { $0.contains(point) }) else { return false }

        let sorted = chipFrames.sorted { $0.minX < $1.minX }
        guard let first = sorted.first, let last = sorted.last else { return false }

        // 两端空白。
        if point.x < first.minX || point.x > last.maxX { return true }

        // 中间：只认落进"够宽的那道缝"的点。用 maxX 的滚动最大值而不是前一个 chip 的 maxX——
        // 帧可能有重叠（消息区外扩过的帧、拖动中的临时位置），逐个比才不会把重叠算成缝。
        var gapStart = first.maxX
        for frame in sorted.dropFirst() {
            if point.x < frame.minX {
                let width = frame.minX - gapStart
                return width >= minimumGapWidth && point.x >= gapStart
            }
            gapStart = max(gapStart, frame.maxX)
        }
        return false
    }

    /// Native-tier width of the gap around a zone divider, chip edge to chip edge: the 1pt
    /// hairline, its side padding and one `chipSpacing` each side. `DockStripView` derives the
    /// divider's padding from it.
    static let dividerGapWidth: CGFloat = 13

    /// Native-tier clearance the drag-to-resize grip keeps from every chip. Callers pass
    /// `defaultGripChipClearance * scale`. 2.5pt leaves an 8pt band in the divider gap: the ▲▼
    /// cursor is 9pt wide and does not scale, so at the band's edge it stays ~2pt short of the
    /// icon artwork. Must stay below half the divider gap, or the grip disappears there.
    static let defaultGripChipClearance: CGFloat = 2.5

    /// The drag-to-resize grip: the right-click zones minus `chipClearance` on each side of
    /// every chip (x only — the gap test above is x only too). The right-click zone itself
    /// stays the full gap.
    ///
    /// The end insets are the grip's **fallback only**: while any divider gap exists the grip
    /// lives there alone, and the ends take over when the bar has a single zone and therefore
    /// no divider. Right-click keeps the ends either way.
    static func gripClaims(
        point: CGPoint,
        chipFrames: [CGRect],
        bounds: CGRect,
        minimumGapWidth: CGFloat,
        chipClearance: CGFloat
    ) -> Bool {
        guard claims(point: point, chipFrames: chipFrames, bounds: bounds,
                     minimumGapWidth: minimumGapWidth) else { return false }
        guard !chipFrames.contains(where: {
            point.x > $0.minX - chipClearance && point.x < $0.maxX + chipClearance
        }) else { return false }
        let isEndInset = !chipFrames.contains { $0.minX <= point.x }
            || !chipFrames.contains { $0.maxX >= point.x }
        return !isEndInset || !hasDividerGap(chipFrames: chipFrames, minimumGapWidth: minimumGapWidth)
    }

    /// Whether any chip-to-chip gap is wide enough to be a zone divider's — the same running-max
    /// walk as `claims`, so an overlap never reads as a gap.
    static func hasDividerGap(chipFrames: [CGRect], minimumGapWidth: CGFloat) -> Bool {
        let sorted = chipFrames.sorted { $0.minX < $1.minX }
        guard var gapStart = sorted.first?.maxX else { return false }
        for frame in sorted.dropFirst() {
            if frame.minX - gapStart >= minimumGapWidth { return true }
            gapStart = max(gapStart, frame.maxX)
        }
        return false
    }
}
