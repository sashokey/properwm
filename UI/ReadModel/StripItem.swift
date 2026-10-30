import CoreGraphics
import Foundation

enum WindowDisplayTitle {
    static func resolve(rawTitle: String?, fallbackName: String) -> String {
        let title = rawTitle.flatMap { title in
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        } ?? fallbackName
        return title == "ProperWM" ? String(localized: "Taskbar") : title
    }

    static func trimmingAppNameSuffix(_ title: String, appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, title.hasSuffix(app), title != app else { return title }

        var head = Substring(title).dropLast(app.count)
        guard let separator = separators.first(where: { head.hasSuffix($0) }) else { return title }
        head = head.dropLast(separator.count)

        let remainder = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? title : remainder
    }

    private static let separators = [" - ", " — ", " – ", " | ", " · ", "-", "—", "–", "|"]
}

struct StripItem: Hashable {
    let id: String
    let title: String
    let status: String
    let appID: String
    let bundleIdentifier: String?
    let sameAppCardCount: Int
    let showsTitle: Bool
    let isAppLevelFallback: Bool
    let canMinimize: Bool
    let canClose: Bool
    let isOnDesktop: Bool
    let cgWindowID: CGWindowID?
    let bounds: CGRect?
    let pid: Int32
    let displayUUID: String?
    let actionWindowID: String
    let memberWindowIDs: [String]

    init(members: [WindowRecord], sameAppCardCount: Int = 1) {
        let anchor = members.min { ($0.cgWindowID ?? .max) < ($1.cgWindowID ?? .max) } ?? members[0]
        let token = members[0].groupID
        let representative = members.first { $0.status == .active }
            ?? members.first { $0.status != .minimized && $0.status != .hidden }
            ?? anchor

        self.id = token
        self.actionWindowID = representative.id.rawValue
        self.memberWindowIDs = members.map(\.id.rawValue)
        self.title = representative.title
        self.status = representative.status.rawValue
        self.appID = representative.appID.rawValue
        self.bundleIdentifier = representative.bundleIdentifier
        self.sameAppCardCount = sameAppCardCount
        self.showsTitle = sameAppCardCount >= 2
        self.isAppLevelFallback = token.hasPrefix("app-")
        self.canMinimize = self.isAppLevelFallback == false
        self.canClose = self.isAppLevelFallback == false
        self.isOnDesktop = representative.isOnDesktop
        self.cgWindowID = representative.cgWindowID
        self.bounds = representative.bounds
        self.pid = representative.pid
        self.displayUUID = representative.displayUUID
    }

    init(record: WindowRecord, sameAppCardCount: Int = 1) {
        self.init(members: [record], sameAppCardCount: sameAppCardCount)
    }

    static func items(from snapshot: DockSnapshot) -> [StripItem] {
        makeItems(records: snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] })
    }

    static func openWindows(from snapshot: DockSnapshot) -> [StripItem] {
        let records = snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] }.filter {
            !$0.groupID.hasPrefix("app-") && $0.status != .disappeared
        }
        return makeItems(records: records)
    }

    private static func makeItems(records: [WindowRecord]) -> [StripItem] {

        var slots: [[WindowRecord]] = []
        var slotIndexByKey: [String: Int] = [:]
        for record in records {
            let key = tabGroupKey(for: record)
            if let key, let idx = slotIndexByKey[key] {
                slots[idx].append(record)
            } else {
                if let key { slotIndexByKey[key] = slots.count }
                slots.append([record])
            }
        }

        let countByApp = Dictionary(grouping: slots) { appGroupingKey(for: $0[0]) }
            .mapValues(\.count)

        return slots.map { members in
            StripItem(members: members, sameAppCardCount: countByApp[appGroupingKey(for: members[0])] ?? 1)
        }
    }

    private static func appGroupingKey(for record: WindowRecord) -> String {
        record.bundleIdentifier ?? record.appID.rawValue
    }

    private static func tabGroupKey(for record: WindowRecord) -> String? {
        guard record.cgWindowID != nil else { return nil }
        return record.groupID
    }
}

enum StripOrdering {
    enum PlacementReason: String, Codable, Equatable {
        case sameAppSibling
        case tail
    }

    struct Placement: Equatable {
        let chipID: String
        let index: Int
        let reason: PlacementReason
    }

    struct ReconcileResult: Equatable {
        let order: [String]
        let placements: [Placement]
    }

    static func reconcile(remembered: [String], current: [String], appKeyOf: [String: String] = [:]) -> [String] {
        reconcileWithTrace(
            remembered: remembered,
            current: current,
            appKeyOf: appKeyOf
        ).order
    }

    static func reconcileWithTrace(
        remembered: [String],
        current: [String],
        appKeyOf: [String: String] = [:]
    ) -> ReconcileResult {
        let currentSet = Set(current)
        let rememberedSet = Set(remembered)
        var result = remembered.filter { currentSet.contains($0) }
        var placements: [Placement] = []
        for id in current where !rememberedSet.contains(id) {
            let app = appKeyOf[id]
            if let app, let pos = result.lastIndex(where: { appKeyOf[$0] == app }) {
                result.insert(id, at: pos + 1)
                placements.append(Placement(chipID: id, index: pos + 1, reason: .sameAppSibling))
            } else {
                result.append(id)
                placements.append(Placement(chipID: id, index: result.count - 1, reason: .tail))
            }
        }
        return ReconcileResult(order: result, placements: placements)
    }

    static func reordering(_ order: [String], move draggedID: String, relativeTo targetID: String, after: Bool) -> [String] {
        guard draggedID != targetID, order.contains(draggedID), order.contains(targetID) else { return order }
        var result = order
        result.removeAll { $0 == draggedID }
        guard let t = result.firstIndex(of: targetID) else { return order }
        result.insert(draggedID, at: after ? t + 1 : t)
        return result
    }

    static func persistableLiveOrder(_ order: [String]) -> [String] {
        order.filter { $0.hasPrefix("tabgrp-") }
    }
}
