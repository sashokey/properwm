import CoreGraphics

/// 「指针在不在任务条上」的进 / 出迟滞框（纯几何，单测覆盖）。进得松、出得远，中间是迟滞带：
/// 边界上抖一下不翻转。两套口径：
/// - `.drawerConversion`：抽屉图标往下拖到条上转正 / 撤销。上方放得很宽（进 16 / 出 40），
///   因为指针是从上面下来的，靠近条时不能一抖就撤销转正。
/// - `.stripPresence`：条上起拖的载荷离开 / 回到条（拖出即合拢）。上方按原生 Dock 对齐（进 0 / 出 6）：
///   指针一出条顶空位就合上、一回到条内空位就在指针下重开——原生录屏逐帧量的（owner 2026-09-03，
///   先前 24pt 被报「要抬很高任务条才合拢」）。6pt 迟滞带只挡指针抖动。
///
/// 右侧都要一直伸到抽屉入口胶囊外缘（`rightReach` = 胶囊间距 + 胶囊宽）：抽屉最右一列往下拖时
/// 光标全程落在胶囊上，不并进来就永远进不了框（2026-08-18 实测整趟 60 帧 enter 全 false）；
/// 反过来条上的图标横移到胶囊上也仍算在条上，让位不合拢。
struct StripPointerBox: Equatable {
    enum Profile {
        case drawerConversion
        case stripPresence

        /// 条顶之上还算「进」/ 算「清楚出」的高度。
        var topEnter: CGFloat { self == .drawerConversion ? 16 : 0 }
        var topOut: CGFloat { self == .drawerConversion ? 40 : 6 }
    }

    let enter: Bool
    let clearlyOut: Bool

    /// - Parameters:
    ///   - pointer: 屏幕坐标（bottom-left）。
    ///   - stripRect: 任务条根视图的屏幕 rect（`DockStripView.stripRootScreenRect`）。
    ///   - rightReach: 条右缘之外还算「在条上」的宽度（胶囊）。
    static func classify(pointer g: CGPoint, stripRect r: CGRect, rightReach: CGFloat,
                         profile: Profile) -> StripPointerBox {
        let enter      = g.x >= r.minX - 8  && g.x <= r.maxX + rightReach
                      && g.y >= r.minY - 8  && g.y <= r.maxY + profile.topEnter
        let clearlyOut = g.x < r.minX - 24  || g.x > r.maxX + rightReach + 16
                      || g.y < r.minY - 24  || g.y > r.maxY + profile.topOut
        return StripPointerBox(enter: enter, clearlyOut: clearlyOut)
    }
}
