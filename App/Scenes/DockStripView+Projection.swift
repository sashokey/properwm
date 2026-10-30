import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · 投影构建：一次 body 求值只建一份 StripProjection（性能规则），标签去重、appKey。
// 2026-09-05 从 DockStripView.swift 按 extension 拆出，只搬不改。
extension DockStripView {
    /// Pinned messaging zone (leftmost, in store order) + live window zone, in **natural**
    /// snapshot order. Messaging apps show only while running (quit → chip gone; the future
    /// drawer 待启动区 takes over the not-running role). Drawer membership hides a messaging
    /// app from the strip without clearing its messaging flag.
    ///
    /// 方案 B: each messaging app pins exactly ONE app-level chip. Its main window
    /// (title matches the app name) is absorbed into that chip; pop-out windows
    /// (chat windows etc.) flow through the live zone as normal window chips so the
    /// pinned zone keeps a stable width (muscle memory).
    ///
    /// Split out so the live zone can be reordered by `stripOrderStore` (任务条拖动重排
    /// A 路线) while the pinned messaging zone keeps its own `MessagingAppStore` order —
    /// the two zones never cross (拖动分区内进行).
    func makeProjection() -> StripProjection {
        let snapshotItems = StripItem.openWindows(from: runtime.snapshot)
        let liveNatural = snapshotItems.map(StripEntry.window)
        let liveOrderIDs = liveNatural.map(\.id)
        let appKeys = Self.appKeys(of: liveNatural)
        let order = stripOrderStore.reconciled(current: liveOrderIDs, appKeyOf: appKeys)
        let byID = Dictionary(liveNatural.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = order.compactMap { byID[$0] }
        let table = displayTopologyStore.table
        let filter = StripDisplayFilter(
            scope: displayUUID,
            connectedUUIDs: table.connectedUUIDs,
            primaryUUID: table.primaryUUID
        )
        var otherDisplayIDs = Set<String>()
        let entries = ordered.filter { entry in
            guard case let .window(item) = entry else { return false }
            let shows = filter.shows(.window(displayUUID: item.displayUUID))
            if !shows { otherDisplayIDs.insert(item.id) }
            return shows
        }
        let labels = Self.labelTitles(for: entries, heldTitles: runtime.heldLabelTitlesByChipID)
        let draggingID: String?
        if ownsActiveDrag, let payload = dragController.hiddenSlotPayload,
           payload.source == .strip, liveOrderIDs.contains(payload.id) {
            draggingID = payload.id
        } else {
            draggingID = nil
        }
        return StripProjection(
            otherDisplayIDs: otherDisplayIDs,
            snapshotItems: snapshotItems,
            snapshotBundleIDs: Set(snapshotItems.compactMap(\.bundleIdentifier)),
            hiddenBundleIDs: Set(snapshotItems.filter { $0.status == "hidden" }.compactMap(\.bundleIdentifier)),
            messaging: [],
            liveNatural: liveNatural,
            liveOrderIDs: liveOrderIDs,
            appKeyByChipID: appKeys,
            labelTitleByChipID: labels,
            entries: entries,
            layoutKeys: entries.map(StripLayoutKey.init),
            messagingIDs: [],
            draggingID: draggingID,
            badgeEntryIDByBundle: [:],
            frontWindowChipIDs: []
        )
    }

    private static func labelTitles(for entries: [StripEntry], heldTitles: [String: String]) -> [String: String] {
        var itemsByApp: [String: [(id: String, title: String)]] = [:]
        for case let .window(item) in entries {
            let appName = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
            let resolved = WindowDisplayTitle.resolve(rawTitle: heldTitles[item.id] ?? item.title, fallbackName: appName)
            let withoutApp = WindowDisplayTitle.trimmingAppNameSuffix(resolved, appName: appName)
            itemsByApp[item.bundleIdentifier ?? item.appID, default: []].append((item.id, withoutApp))
        }

        var labels: [String: String] = [:]
        for (_, group) in itemsByApp {
            let trimmed = StripSharedAffixTrim.trimmingSharedAffixes(group.map(\.title))
            for (entry, label) in zip(group, trimmed) { labels[entry.id] = label }
        }
        return labels
    }

    /// **`onChange` 闭包里必须用它，不能用闭包捕获的 `projection`。**
    ///
    /// 老式 `onChange(of:perform:)` 触发时跑的是**上一帧**装进去的闭包，里面那份 projection
    /// 因此永远落后一代。平时无所谓（下一次变化会追上），但抽屉转正那一刻是致命的
    /// （实测 2026-08-18：渲染已经是 12 张卡了，`sync` 收到的还是 11 张，不含刚冒出来的占位）：
    ///
    /// 1. `sync` 里 `next.contains("app-<bid>")` 为 false → **落点暂存一次都没被消费**；
    /// 2. 记忆序 `liveOrder` 因此始终没有这个 id → 后续 `reorderBlock` 的 `movingBlock`
    ///    找不到要移动的 id，**每一次都原样返回**（日志里五次 `ok` 全是空转）；
    /// 3. 渲染只能退回 `reconciled` 的 kept 稳定名次，把它钉在一个跟光标无关的固定位置。
    ///
    /// 也就是 owner 说的「不容易触发把其他图标挤走」。这里重建一次 projection 的代价可以接受：
    /// 它只在 live 区卡的集合真的变了时触发，不是每帧、更不是每次鼠标移动。
    /// （AGENTS 那条「一次 body 只建一个 projection」管的是**渲染路径**，这里是副作用路径。）
    func freshProjection() -> StripProjection { makeProjection() }

    /// 渲染路径（`reconciled`）与副作用路径（`sync`）**必须喂同一份 appKeyOf**，否则落盘的记忆序
    /// 与显示序不一致。抽成一个函数，让两条路径无从写岔。
    static func appKeys(of liveNatural: [StripEntry]) -> [String: String] {
        Dictionary(liveNatural.map { entry -> (String, String) in
            switch entry {
            case let .window(item): return (entry.id, item.bundleIdentifier ?? item.appID)
            case let .keptApp(bid): return (entry.id, bid)
            default: return (entry.id, entry.id)
            }
        }, uniquingKeysWith: { first, _ in first })
    }
}
