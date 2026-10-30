import Foundation

/// 多屏任务条的单元集合纯判定（③④，2026-09-02）。编排层据此决定要建 / 拆哪些
/// `PanelCoordinator` 单元。**按 display UUID 记屏，永不按 `NSScreen.screens` 序号。**
enum TaskbarDisplaySet {
    struct Diff: Equatable {
        /// 顺序与 `current` 一致。
        let added: [String]
        /// 顺序与 `previous` 一致。
        let removed: [String]
        /// 顺序与 `current` 一致。
        let kept: [String]
    }

    static func diff(previous: [String], current: [String]) -> Diff {
        let previousSet = Set(previous)
        let currentSet = Set(current)
        return Diff(
            added: current.filter { !previousSet.contains($0) },
            removed: previous.filter { !currentSet.contains($0) },
            kept: current.filter { previousSet.contains($0) }
        )
    }

    /// 期望存在的单元 key：①② 恰好一个「跟随设置」的单元（nil），③④ 每块在场屏一个。
    /// `connectedKeys` 为空时（所有屏都拔了、或 UUID 全读不到）退化为单单元，任务条不会凭空消失。
    static func desiredUnitKeys(placement: TaskbarScreenPlacement, connectedKeys: [String]) -> [String?] {
        guard placement.showsOnEveryDisplay, !connectedKeys.isEmpty else { return [nil] }
        return connectedKeys
    }
}
