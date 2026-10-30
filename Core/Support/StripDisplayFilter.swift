import Foundation

/// 多屏 ④ 下一条任务条该不该画某个条目。**只在共享顺序层之后**用（`DockStripView.makeProjection`
/// 里 `orderedLive` 之后）：喂给 `StripOrderStore.reconciled / sync / reorder` 的 id 集合各屏必须
/// 一致，否则各屏互相把对方的卡打成「缺席」、5s 后踢出记忆。
///
/// - `scope == nil`：不过滤（①②③，或 ④ 下的非固定单元）。
/// - `.launcher`（没运行的保留占位、消息区、文件夹、中转站）恒显示——它们不是窗口、也没有运行圆点。
/// - `.runningWithoutWindow`（应用级兜底卡、在运行但只剩占位的保留应用）只在一条上：它的窗口最后所在的屏
///   （`AppEntry.lastWindowDisplayUUID`，拖到别的条上也改它），读不到 → 主屏（菜单栏屏）。
///   **有运行圆点 = 只在一条上**（owner 2026-09-02，看到 Chrome 关完窗口两条都出现它）。
/// - `.window`：归属键为 nil（清单读不到位置）或指向已不在场的屏 → 只落主屏；否则键 == scope。
struct StripDisplayFilter: Equatable {
    enum Subject: Equatable {
        case launcher
        case runningWithoutWindow(displayUUID: String?)
        case window(displayUUID: String?)
    }

    let scope: String?
    let connectedUUIDs: Set<String>
    let primaryUUID: String?

    static let unfiltered = StripDisplayFilter(scope: nil, connectedUUIDs: [], primaryUUID: nil)

    func shows(_ subject: Subject) -> Bool {
        guard let scope else { return true }
        switch subject {
        case .launcher:
            return true
        case .runningWithoutWindow(let key), .window(let key):
            guard let key, connectedUUIDs.contains(key) else { return scope == primaryUUID }
            return key == scope
        }
    }
}
