import Foundation

final class StripProjectionRegistry {
    struct Record {
        let projection: StripProjection
        let displayUUID: String?
    }

    static let shared = StripProjectionRegistry()
    private let lock = NSLock()
    private var records: [String: Record] = [:]

    func store(_ projection: StripProjection, surface: String, displayUUID: String?) {
        lock.lock()
        records[surface] = Record(projection: projection, displayUUID: displayUUID)
        lock.unlock()
    }

    func remove(surface: String) {
        lock.lock()
        records.removeValue(forKey: surface)
        lock.unlock()
    }

    func snapshot() -> [String: Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    static func exclusion(token: String, cgID: UInt32, bundleID: String?, in projection: StripProjection) -> String {
        if projection.otherDisplayIDs.contains(token) { return "otherDisplay" }
        return "unknown"
    }
}
