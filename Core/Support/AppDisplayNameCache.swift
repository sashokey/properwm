import Foundation

final class AppDisplayNameCache {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for bundleID: String, loader: () -> String?) -> String {
        lock.lock()
        let cached = values[bundleID]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = loader(), !resolved.isEmpty, resolved != bundleID else {
            return bundleID
        }
        lock.lock()
        values[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    func invalidate(bundleID: String) {
        lock.lock()
        values.removeValue(forKey: bundleID)
        lock.unlock()
    }
}
