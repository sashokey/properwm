import CoreGraphics
import Foundation

/// 跨屏拖窗（多屏 ③④）：窗口图标从一块屏的任务条拖到另一块屏的任务条上，窗口搬到那块屏。
/// 纯几何：尺寸不变（超过目标屏可用区就缩到可用区），位置 = 相对**来源屏可用区**左上角的同样偏移，
/// 夹进目标屏可用区；来源未知 → 目标可用区居中。全部 Quartz 坐标（左上原点）。
enum WindowDisplayMove {
    static func targetFrame(window: CGRect,
                            from source: WindowDisplayAttribution.Display?,
                            to target: WindowDisplayAttribution.Display) -> CGRect {
        let area = target.visibleCGFrame
        let width = min(window.width, area.width)
        let height = min(window.height, area.height)
        var origin: CGPoint
        if let source {
            let offset = CGPoint(x: window.minX - source.visibleCGFrame.minX,
                                 y: window.minY - source.visibleCGFrame.minY)
            origin = CGPoint(x: area.minX + offset.x, y: area.minY + offset.y)
        } else {
            origin = CGPoint(x: area.midX - width / 2, y: area.midY - height / 2)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - width)
        origin.y = min(max(origin.y, area.minY), area.maxY - height)
        // 只对原点取整，尺寸原样保留（`.integral` 会在半像素处把尺寸撑大 1pt）。
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }

    /// 搬窗成没成：看回读帧**归属到的屏**是不是目标屏，不看它和请求帧差几 pt。跨屏搬窗时 AppKit
    /// 常自己修正几 pt（菜单栏 / 可用区约束、两块屏缩放不同），按 ±2pt 判失败会把已经搬过去的
    /// 窗口又挪回来（owner 2026-09-03：「窗口到了 B，闪一下，窗口和卡都回到 A」）。
    static func landedOnTarget(actual: CGRect, target: String, table: WindowDisplayAttribution.Table) -> Bool {
        WindowDisplayAttribution.displayUUID(for: actual, table: table) == target
    }
}
