import Foundation

enum TaskbarDisplaySet {
    static func desiredUnitKeys(connectedKeys: [String], physicalDisplayCount: Int) -> [String?] {
        guard physicalDisplayCount > 0 else { return [] }
        guard !connectedKeys.isEmpty else { return [nil] }
        return connectedKeys
    }
}
