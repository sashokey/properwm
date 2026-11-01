import AppKit
import CoreServices

@MainActor
enum AppDisplayNameResolver {
    private static let displayNameCache = AppDisplayNameCache()
    private static let workspaceObservers: [NSObjectProtocol] = {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        return names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    invalidateDisplayName(for: bundleID)

                }
            }
        }
    }()

    static func displayName(for bundleID: String) -> String {
        _ = workspaceObservers
        return displayNameCache.value(for: bundleID) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = running.localizedName, !name.isEmpty {
                return name
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return notRunningDisplayName(at: url)
        }
    }

    private static func notRunningDisplayName(at url: URL) -> String? {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let spotlight = sanitizedDisplayName(MDItemCopyAttribute(item, kMDItemDisplayName) as? String) {
            return spotlight
        }
        let bundle = Bundle(url: url)
        for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = sanitizedDisplayName(dict?[key] as? String) { return name }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func sanitizedDisplayName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        if name.hasSuffix(".app"), name.count > 4 {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    static func invalidateDisplayName(for bundleID: String) {
        displayNameCache.invalidate(bundleID: bundleID)
    }

}
