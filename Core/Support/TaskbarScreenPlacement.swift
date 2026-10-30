import Foundation

enum TaskbarUnitPlacement: Equatable {
    case primary
    case fixed(displayUUID: String)
}

enum TaskbarScreenResolution {
    enum Outcome: Equatable {
        case matched(index: Int)
        case fallback(index: Int)
    }

    static func resolve(pinnedUUID: String, screenUUIDs: [String?], mainIndex: Int?) -> Outcome? {
        guard !screenUUIDs.isEmpty else { return nil }
        if let index = screenUUIDs.firstIndex(where: { $0 == pinnedUUID }) {
            return .matched(index: index)
        }
        if let mainIndex, screenUUIDs.indices.contains(mainIndex) {
            return .fallback(index: mainIndex)
        }
        return .fallback(index: 0)
    }

}

