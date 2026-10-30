import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

enum StripEntry: Identifiable, Hashable {
    case window(StripItem)

    var id: String {
        switch self {
        case let .window(item): return item.id
        }
    }
}

struct StripProjection {
    var drawerBundleIDs: [String] = []
    var messagingAbsorbedIDs: Set<String> = []
    var trashAbsorbedIDs: Set<WindowID> = []
    var otherDisplayIDs: Set<String> = []
    let snapshotItems: [StripItem]
    let snapshotBundleIDs: Set<String>
    let hiddenBundleIDs: Set<String>
    let messaging: [StripEntry]
    let liveNatural: [StripEntry]
    let liveOrderIDs: [String]
    let appKeyByChipID: [String: String]
    let labelTitleByChipID: [String: String]
    let entries: [StripEntry]
    let layoutKeys: [StripLayoutKey]
    let messagingIDs: [String]
    let draggingID: String?
    let badgeEntryIDByBundle: [String: String]
    let frontWindowChipIDs: Set<String>

    func hasRealWindow(bundleID: String) -> Bool {
        snapshotItems.contains {
            $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
        }
    }

    func item(forID id: String) -> StripItem? {
        guard let entry = liveNatural.first(where: { $0.id == id }),
              case let .window(item) = entry else { return nil }
        return item
    }

    func liveChipIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            guard case let .window(item) = entry,
                  item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback else { return nil }
            return item.id
        }
    }

    func liveEntryIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case let .window(item):
                return item.bundleIdentifier == bundleID ? item.id : nil
            default:
                return nil
            }
        }
    }
}

struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case zero, single, multi, launcher }

    init(_ entry: StripEntry) {
        id = entry.id
        switch entry {
        case let .window(item):
            form = item.showsTitle ? .multi : .single
        }
    }

}
