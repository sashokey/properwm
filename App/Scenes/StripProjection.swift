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
    var otherDisplayIDs: Set<String> = []
    let liveNatural: [StripEntry]
    let liveOrderIDs: [String]
    let appKeyByChipID: [String: String]
    let labelTitleByChipID: [String: String]
    let entries: [StripEntry]
    let layoutKeys: [StripLayoutKey]
    let draggingID: String?

    func item(forID id: String) -> StripItem? {
        guard let entry = liveNatural.first(where: { $0.id == id }),
              case let .window(item) = entry else { return nil }
        return item
    }

}

struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case single, multi }

    init(_ entry: StripEntry) {
        id = entry.id
        switch entry {
        case let .window(item):
            form = item.showsTitle ? .multi : .single
        }
    }

}
