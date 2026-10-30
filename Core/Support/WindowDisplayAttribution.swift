import CoreGraphics
import Foundation

/// 窗口归哪块屏（多屏 ④「各屏只显示本屏窗口」的粗粒度键）。
///
/// 纯几何：面积过半的那块屏；没有过半取重叠最大的；一点不沾 / 帧无效 / 屏表为空 → nil。
/// 判据复用 `WindowLiftAvoidance.owningContextIndex`（避让已用同一面积法给跨屏窗口分屏）。
/// **这里不落主屏**：清单层老实存「未知」，落主屏是任务条投影层（`StripDisplayFilter`）的事，
/// 否则主屏拔掉 / 换主屏时清单里会留着一个过期的假归属。
enum WindowDisplayAttribution {
    struct Display: Equatable {
        let uuid: String
        /// Quartz 全局坐标（左上原点，锚在菜单栏那块屏），与 AX `kAXPosition` / CG `kCGWindowBounds` 同一坐标系。
        let cgFrame: CGRect
        /// 去掉菜单栏 / 系统 Dock 后的可用区（同坐标系）。跨屏拖窗（`WindowDisplayMove`）按它摆窗口；
        /// 归属判定仍按 `cgFrame`。不传 = 整块屏。
        let visibleCGFrame: CGRect

        init(uuid: String, cgFrame: CGRect, visibleCGFrame: CGRect? = nil) {
            self.uuid = uuid
            self.cgFrame = cgFrame
            self.visibleCGFrame = visibleCGFrame ?? cgFrame
        }
    }

    struct Table: Equatable {
        let displays: [Display]
        /// 菜单栏那块屏（`NSScreen.screens.first`，**不是** `NSScreen.main`）。
        let primaryUUID: String?

        static let empty = Table(displays: [], primaryUUID: nil)

        var connectedUUIDs: Set<String> { Set(displays.map(\.uuid)) }
    }

    static func displayUUID(for quartzFrame: CGRect?, table: Table) -> String? {
        guard let frame = quartzFrame,
              let index = WindowLiftAvoidance.owningContextIndex(
                  for: frame,
                  screenCGFrames: table.displays.map(\.cgFrame)
              ) else { return nil }
        return table.displays[index].uuid
    }
}
