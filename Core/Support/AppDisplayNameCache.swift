import Foundation

final class AppDisplayNameCache {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var order: [String] = []

    func value(for bundleID: String, loader: () -> String?) -> String {
        lock.lock()
        let cached = values[bundleID]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = loader(), !resolved.isEmpty, resolved != bundleID else {
            return bundleID
        }
        let bounded = BoundedText.utf8(resolved)
        lock.lock()
        if values[bundleID] == nil { order.append(bundleID) }
        values[bundleID] = bounded
        while order.count > 512 { values.removeValue(forKey: order.removeFirst()) }
        lock.unlock()
        return bounded
    }

    func invalidate(bundleID: String) {
        lock.lock()
        values.removeValue(forKey: bundleID)
        order.removeAll { $0 == bundleID }
        lock.unlock()
    }
}
