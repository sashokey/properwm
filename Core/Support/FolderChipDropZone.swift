import CoreGraphics

/// 固定文件夹 chip 拖动松手时的落点分类（纯函数，进单测）。
///
/// 坐标系：调用方先把 `DragController.globalLocation`（屏幕坐标）通过 `stripPoint(from:)`
/// 换算成 "strip" 局部坐标点，再传给 `classify`。`stripVisibleRect` 是任务条内容可见区域
/// （"strip" 局部坐标下就是 `(0,0)`–`stripRootScreenRect.size`，天然不含 shadowPadding 透明边，
/// 不需要额外换算）。`folderZoneMinX` 是固定文件夹区（文件夹 chip）在同一坐标系下的左边界：
/// the zone runs from there to the bar's right end (the Trash, when shown, is its last cell), and
/// everything left of it is the window zone and the pinned-app zone (shelf included).
/// 边界不加缓冲——owner 反馈明确要求「命中范围按可见区域算，不留大缓冲区」。
enum FolderChipDropZone: Equatable {
    /// 仍在固定区内：区内重排已在拖动过程中实时提交，松手无额外动作。
    case folderZone
    /// 落在任务条窗口区：取消固定 + 打开该文件夹的真实 Finder 窗口（调用方负责，非本类型职责）。
    case liveZone
    /// 落在任务条可见范围外：移除固定。
    case outsideStrip

    /// The zone's left edge while a folder chip is dragged. `nil` = not measured yet (install no
    /// geometry; the drop falls back to `.folderZone`, a no-op). An empty frame table is **not**
    /// always "not measured": once the only pinned folder leaves the bar its slot collapses and
    /// its frame is gone, and treating that as unmeasured turns the drag-out into a no-op. The
    /// zone is then the Trash alone, or nothing at all — the bar's right edge.
    static func zoneMinX(folderMinX: CGFloat?, draggedSlotCollapsed: Bool,
                         trashMinX: CGFloat?, stripWidth: CGFloat) -> CGFloat? {
        if let folderMinX { return folderMinX }
        guard draggedSlotCollapsed else { return nil }
        return trashMinX ?? stripWidth
    }

    static func classify(point: CGPoint, stripVisibleRect: CGRect, folderZoneMinX: CGFloat) -> FolderChipDropZone {
        guard stripVisibleRect.contains(point) else { return .outsideStrip }
        // A folder chip released over the Trash is a no-op: the Trash is inside this range.
        return point.x >= folderZoneMinX ? .folderZone : .liveZone
    }
}

/// 固定文件夹拖拽的屏幕坐标几何快照。
///
/// `DragController` 的最终 mouseUp 坐标是屏幕坐标；这里封装成纯转换，避免最终落定再依赖
/// SwiftUI 手势回调。`stripScreenRect` 是任务条可见内容区屏幕 frame，不含 shadowPadding。
struct FolderChipDropGeometry: Equatable {
    let stripScreenRect: CGRect
    let folderZoneMinX: CGFloat

    func classify(screenPoint: CGPoint) -> FolderChipDropZone {
        guard stripScreenRect != .zero else { return .outsideStrip }
        let localPoint = CGPoint(
            x: screenPoint.x - stripScreenRect.minX,
            y: stripScreenRect.maxY - screenPoint.y
        )
        return FolderChipDropZone.classify(
            point: localPoint,
            stripVisibleRect: CGRect(origin: .zero, size: stripScreenRect.size),
            folderZoneMinX: folderZoneMinX
        )
    }
}
