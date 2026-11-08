import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()
    let changes = PassthroughSubject<Void, Never>()

    private enum Stamp {
        case unknown
        case known(AppIconStamp?)
    }

    private struct CachedIcon {
        let image: NSImage
        let path: String?
        let generation: UInt64
        var stamp: Stamp = .unknown
    }

    private var cache: [String: CachedIcon] = [:]
    private var generation: UInt64 = 0
    private var lastKnownPaths: [String: String] = [:]
    private let notifications: NotificationCenter
    private let applicationURL: (String) -> URL?
    private let imageForFile: (String) -> NSImage
    private let fallbackImage: () -> NSImage
    private let stampAtPath: @Sendable (String) -> AppIconStamp?
    private var observers: [NSObjectProtocol] = []
    private lazy var freshnessChecker = AppIconFreshnessChecker(
        snapshot: { [weak self] onlyUninitialized in
            self?.cache.compactMap { key, entry in
                guard let path = entry.path else { return nil }
                if onlyUninitialized, case .known = entry.stamp { return nil }
                return AppIconFreshnessChecker.Entry(key: key, path: path, generation: entry.generation, stamp: nil)
            } ?? []
        },
        didCheck: { [weak self] entries in
            guard let self else { return }
            var changed = false
            for entry in entries {
                guard var current = self.cache[entry.key], current.path == entry.path,
                      current.generation == entry.generation else { continue }
                switch current.stamp {
                case .unknown:
                    current.stamp = .known(entry.stamp)
                    self.cache[entry.key] = current
                case .known(let stamp) where stamp != entry.stamp:
                    self.cache.removeValue(forKey: entry.key)
                    changed = true
                default:
                    break
                }
            }
            if changed { self.changes.send() }
        },
        stampAtPath: stampAtPath
    )

    init(notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationURL: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         imageForFile: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) },
         fallbackImage: @escaping () -> NSImage = { NSWorkspace.shared.icon(for: .applicationBundle) },
         stampAtPath: @escaping @Sendable (String) -> AppIconStamp? = AppIconStamp.stamp(atPath:)) {
        self.notifications = notifications
        self.applicationURL = applicationURL
        self.imageForFile = imageForFile
        self.fallbackImage = fallbackImage
        self.stampAtPath = stampAtPath
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationStateChanged() }
            })
        }
    }

    isolated deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    private func applicationStateChanged() {
        let unresolved = cache.compactMap { $0.value.path == nil ? $0.key : nil }
        for key in unresolved { cache.removeValue(forKey: key) }
        if !unresolved.isEmpty { changes.send() }
        freshnessChecker.requestCheck()
    }

    func icon(for bundleIdentifier: String, origin: ApplicationOrigin? = nil) -> NSImage {
        let key = origin.map { "path:\($0.bundlePath)" } ?? "bundle:\(bundleIdentifier)"
        if let cached = cache[key] { return cached.image }
        let shared: NSImage
        let path: String?
        if let origin {
            path = origin.bundlePath
            shared = imageForFile(origin.bundlePath)
        } else if let url = applicationURL(bundleIdentifier) {
            if lastKnownPaths[bundleIdentifier] == nil, lastKnownPaths.count >= 512 { lastKnownPaths.removeAll() }
            lastKnownPaths[bundleIdentifier] = url.path
            path = url.path
            shared = imageForFile(url.path)
        } else if let lastPath = lastKnownPaths[bundleIdentifier], FileManager.default.fileExists(atPath: lastPath) {
            path = lastPath
            shared = imageForFile(lastPath)
        } else {
            path = nil
            shared = fallbackImage()
        }
        let icon = (shared.copy() as? NSImage) ?? shared
        let plated = icon.representations.filter { $0.size.width < 128 && CGFloat($0.pixelsWide) <= $0.size.width }
        if plated.count < icon.representations.count { plated.forEach(icon.removeRepresentation) }
        icon.size = NSSize(width: 32, height: 32)
        if cache.count >= 512 { cache.removeAll() }
        generation &+= 1
        cache[key] = CachedIcon(image: icon, path: path, generation: generation)
        if path != nil { freshnessChecker.requestCheck(onlyUninitialized: true) }
        return icon
    }
}
