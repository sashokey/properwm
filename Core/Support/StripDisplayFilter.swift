import Foundation

struct StripDisplayFilter: Equatable {
    let scope: String?
    let connectedUUIDs: Set<String>
    let primaryUUID: String?

    func shows(displayUUID: String?) -> Bool {
        guard let scope else { return true }
        return resolvedWindowDisplayUUID(displayUUID) == scope
    }

    func resolvedWindowDisplayUUID(_ key: String?) -> String? {
        guard let key, connectedUUIDs.contains(key) else { return primaryUUID }
        return key
    }
}
