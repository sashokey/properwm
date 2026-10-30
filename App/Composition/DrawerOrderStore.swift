import Foundation

/// 抽屉显示顺序层（抽屉内拖动排序，2026-06-21）。抽屉是 **app 视角**：一个 bundleID 一个图标，
/// 顺序按 bundleID 永久记住——bundleID 跨重启稳定，不像任务条 cgWindowID 有开机周期顾虑，所以
/// 抽屉顺序可无条件落盘、永久保留。
///
/// **命门：按 placement 全集记顺序，不按当前可见图标裁。** 未 kept 的成员退出时会隐藏，
/// 但它的 placement 与相对顺序仍保留，下一次启动回到原位。
///
/// 与 `StripOrderStore` 同形但更简单：没有开机周期守卫（bundleID 不复用）、没有缺席 grace
/// （成员集合稳定、不像窗口会闪断）。
@MainActor
final class DrawerOrderStore: ObservableObject {
    @Published private(set) var order: [String] = []
    private let key = "drawerDisplayOrder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: key) ?? []
    }

    /// 显示顺序 = 记住的顺序 ∩ 当前成员全集，新成员追加末尾。纯函数，可在 body 里读。
    func reconciled(members: [String]) -> [String] {
        let memberSet = Set(members)
        var result = order.filter { memberSet.contains($0) }
        let known = Set(result)
        for m in members where !known.contains(m) { result.append(m) }
        return result
    }

    /// 成员全集变化时收敛持久顺序。**作为副作用调用，绝不在 body 求值期间调。**
    func sync(members: [String]) {
        let next = reconciled(members: members)
        if next != order { order = next; persist() }
    }

    /// Mirrors MessagingAppStore.reorder: operate on the full persisted order so
    /// hidden placements keep their relative order while visible peers move.
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              let from = order.firstIndex(of: draggedID) else { return }
        var next = order
        next.remove(at: from)
        guard let target = next.firstIndex(of: targetID) else { return }
        next.insert(draggedID, at: after ? target + 1 : target)
        if next != order { order = next; persist() }
    }

    /// Puts `ids` first, in that order (`DrawerAppDrop.frontOrder`). Ids not yet members are
    /// placed too, so call it before adding them to `DrawerStore`.
    func moveToFront(_ ids: [String]) {
        place(ids, at: .front)
    }

    /// Puts `ids` at `placement` as one block (`DrawerAppDrop.order`); same contract as
    /// `moveToFront`: call it before the ids join `DrawerStore`.
    func place(_ ids: [String], at placement: DrawerAppDrop.Placement) {
        let next = DrawerAppDrop.order(existing: order, dropped: ids, placement: placement)
        if next != order { order = next; persist() }
    }

    private func persist() {
        defaults.set(order, forKey: key)
    }
}
