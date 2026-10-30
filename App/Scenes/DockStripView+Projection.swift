import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

extension DockStripView {
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
            liveNatural: liveNatural,
            liveOrderIDs: liveOrderIDs,
            appKeyByChipID: appKeys,
            labelTitleByChipID: labels,
            entries: entries,
            layoutKeys: entries.map(StripLayoutKey.init),
            draggingID: draggingID
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

    func freshProjection() -> StripProjection { makeProjection() }

    static func appKeys(of liveNatural: [StripEntry]) -> [String: String] {
        Dictionary(liveNatural.map { entry -> (String, String) in
            switch entry {
            case let .window(item): return (entry.id, item.bundleIdentifier ?? item.appID)
            }
        }, uniquingKeysWith: { first, _ in first })
    }
}
