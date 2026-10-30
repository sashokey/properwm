import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AppIconResolver {
    private struct CachedIcon {
        let image: NSImage
        let path: String?
        let stamp: AppIconStamp?
    }

    private static var cache: [String: CachedIcon] = [:]
    private static var lastKnownPaths: [String: String] = [:]
    @MainActor private static let bitmaps = IconBitmapCache()
    private static let logger = Logger(subsystem: "io.github.sashokey.properwm", category: "AppIconResolver")
    private static var activationObserver: NSObjectProtocol?
    private static let freshnessChecker = AppIconFreshnessChecker(
        snapshot: {
            cache.compactMap { bundleID, cached in
                guard let path = cached.path else { return nil }
                return AppIconFreshnessChecker.Entry(key: bundleID, path: path, stamp: cached.stamp)
            }
        },
        didCheck: { entries in
            var invalidated = false
            for entry in entries {
                guard let current = cache[entry.key], current.path == entry.path,
                      current.stamp != entry.stamp else { continue }
                cache.removeValue(forKey: entry.key)
                bitmaps.removeAll(name: entry.key)
                logger.debug("图标变了：\(entry.key, privacy: .public)")
                invalidated = true
            }
            if invalidated { AppIconRevision.shared.advance() }
        }
    )

    private static func observeActivationIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { freshnessChecker.requestCheck() }
        }
    }

    @MainActor
    static func icon(for bundleIdentifier: String, points: CGFloat, displayScale: CGFloat,
                     colorScheme: ColorScheme, allowsRendering: Bool) -> NSImage {
        bitmaps.image(name: bundleIdentifier, points: points, displayScale: displayScale,
                      appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua),
                      allowsRendering: allowsRendering) { icon(for: bundleIdentifier) }
    }

    static func icon(for bundleIdentifier: String) -> NSImage {
        observeActivationIfNeeded()
        if let cached = cache[bundleIdentifier] {
            return cached.image
        }

        let shared: NSImage
        let path: String?
        let stamp: AppIconStamp?
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            if lastKnownPaths[bundleIdentifier] == nil, lastKnownPaths.count >= 512 {
                lastKnownPaths.removeAll()
            }
            lastKnownPaths[bundleIdentifier] = appURL.path
            path = appURL.path
            stamp = AppIconStamp.stamp(atPath: appURL.path)
            logger.debug("取图标：\(bundleIdentifier, privacy: .public)")
            shared = NSWorkspace.shared.icon(forFile: appURL.path)
        } else if let lastPath = lastKnownPaths[bundleIdentifier],
                  FileManager.default.fileExists(atPath: lastPath) {
            path = lastPath
            stamp = AppIconStamp.stamp(atPath: lastPath)
            logger.debug("取图标（按上次路径）：\(bundleIdentifier, privacy: .public)")
            shared = NSWorkspace.shared.icon(forFile: lastPath)
        } else {
            path = nil
            stamp = nil
            shared = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        let icon = (shared.copy() as? NSImage) ?? shared
        removePlatedRepresentations(from: icon)
        icon.size = NSSize(width: 32, height: 32)
        if cache.count >= 512 { cache.removeAll() }   // 只防无限增长；正常一辈子都碰不到
        cache[bundleIdentifier] = CachedIcon(image: icon, path: path, stamp: stamp)
        return icon
    }

    private static func removePlatedRepresentations(from icon: NSImage) {
        let plated = icon.representations.filter {
            $0.size.width < 128 && CGFloat($0.pixelsWide) <= $0.size.width
        }
        guard plated.count < icon.representations.count else { return }
        plated.forEach(icon.removeRepresentation)
    }
}
