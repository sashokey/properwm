import Foundation

final class AppDisplayNameCache {
    private struct Key: Hashable {
        let bundleID: String
        let bundlePath: String?
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]
    private var order: [Key] = []

    func value(for bundleID: String, bundlePath: String? = nil, loader: () -> String?) -> String {
        let key = Key(bundleID: bundleID, bundlePath: bundlePath)
        lock.lock()
        let cached = values[key]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = loader(), !resolved.isEmpty, resolved != bundleID else {
            return bundleID
        }
        let bounded = BoundedText.utf8(resolved)
        lock.lock()
        if values[key] == nil { order.append(key) }
        values[key] = bounded
        while order.count > 512 { values.removeValue(forKey: order.removeFirst()) }
        lock.unlock()
        return bounded
    }

    func invalidate(bundleID: String) {
        lock.lock()
        for key in values.keys where key.bundleID == bundleID { values.removeValue(forKey: key) }
        order.removeAll { $0.bundleID == bundleID }
        lock.unlock()
    }
}
