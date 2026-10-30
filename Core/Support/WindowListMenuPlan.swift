import Foundation

/// 应用级图标右键菜单顶部的「窗口列表」条目（像原生 Dock：✓ = 前台窗口，◇ = 已最小化）。
/// 只出现在「一个图标代表整个应用」的入口（保留 / 消息区 / 抽屉 / 访达常驻卡）；
/// 具体窗口卡自己就是那个窗口，不列（owner 2026-08-24）。
struct WindowMenuEntry: Equatable {
    enum Marker: Equatable {
        case none
        /// 该应用的前台（active）窗口——原生 Dock 打 ✓ 的那一行。
        case front
        /// 整组都已最小化——原生 Dock 打 ◇ 的那一行。点击走 activate，会还原它。
        case minimized
    }

    /// 点击后交给 `runtime.activate(windowID:)` 的动作目标（组的当前代表成员）。
    let actionWindowID: String
    let title: String
    let marker: Marker
}

enum WindowListMenuPlan {
    /// 从快照取某 bundle 的全部窗口，按 strip 顺序、按 `groupID` 折叠（原生标签组一组一行，
    /// 后台标签不单列——与任务条的单座位模型同口径）。**只读快照、不做 AX**：
    /// 菜单在右键瞬间同步构建（menus.md），任何现场盘点都会卡住这一下。
    static func entries(
        snapshot: DockSnapshot,
        bundleID: String,
        fallbackTitle: String
    ) -> [WindowMenuEntry] {
        var groups: [[WindowRecord]] = []
        var indexByGroup: [String: Int] = [:]
        for id in snapshot.orderedWindowIDs {
            guard let record = snapshot.windows[id],
                  record.bundleIdentifier == bundleID,
                  // app-* 兜底座位不是真窗口；已在关闭途中 / 已消失的也不列。
                  !record.groupID.hasPrefix("app-"),
                  record.status != .closedPending,
                  record.status != .disappeared
            else { continue }
            if let idx = indexByGroup[record.groupID] {
                groups[idx].append(record)
            } else {
                indexByGroup[record.groupID] = groups.count
                groups.append([record])
            }
        }
        return groups.map { members in
            // 代表窗与 `StripItem.init(members:)` 同一规则：active ?? 首个可见成员 ?? 首个。
            let representative = members.first { $0.status == .active }
                ?? members.first { $0.status != .minimized && $0.status != .hidden }
                ?? members[0]
            let marker: WindowMenuEntry.Marker
            if representative.status == .active {
                marker = .front
            } else if members.allSatisfy({ $0.status == .minimized }) {
                marker = .minimized
            } else {
                marker = .none
            }
            return WindowMenuEntry(
                actionWindowID: representative.id.rawValue,
                title: WindowDisplayTitle.resolve(
                    rawTitle: representative.title,
                    fallbackName: fallbackTitle
                ),
                marker: marker
            )
        }
    }
}
