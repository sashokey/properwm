import Foundation

@MainActor
final class StripProjectionRegistry {
    struct Record {
        let projection: StripProjection
        let displayUUID: String?
    }

    static let shared = StripProjectionRegistry()
    private var records: [String: Record] = [:]

    func store(_ projection: StripProjection, surface: String, displayUUID: String?) {
        records[surface] = Record(projection: projection, displayUUID: displayUUID)
    }

    func remove(surface: String) {
        records.removeValue(forKey: surface)
    }

    func snapshot() -> [String: Record] {
        return records
    }

    static func exclusion(token: String, cgID: UInt32, bundleID: String?, in projection: StripProjection) -> String {
        if projection.otherDisplayIDs.contains(token) { return "otherDisplay" }
        return "unknown"
    }
}
