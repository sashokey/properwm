import Foundation
import os

/// 「在程序坞中保留」的 app 列表。运行时照常显示窗口卡片；退出后收敛成一个 app 图标留在原位。
///
/// 访达自 2026-08-20 起也由此 store 管（`FinderTaskbarPolicy`），默认勾上、可取消。
/// 顺序由 `StripOrderStore` 统一管，此 store 只负责成员身份与持久化。
@MainActor
final class KeptAppStore: ObservableObject {
    /// V3 lets a messaging app also be kept (kept alone now decides post-exit
    /// visibility). Key existence is the migration marker, including an explicitly
    /// persisted empty array on a fresh install. Older kept keys stay frozen
    /// read-only so a code rollback still reads the exact pre-upgrade list.
    static let defaultsKey = "keptAppBundleIDsV3"
    static let previousDefaultsKey = "keptAppBundleIDsV2"
    /// 访达一次性播种标记。**不能复用 V3 键**——V3 键存在本身已经是迁移标记，
    /// 老用户的 V3 早就写好了，只有一个独立的键能表达「访达那一次补勾做过没有」。
    static let finderSeedKey = "keptAppFinderSeededV1"
    private static let v1Key = "keptAppBundleIDs"
    private static let legacyKey = "pinnedAppBundleIDs"
    private static let drawerKey = "drawerBundleIDs"
    private static let messagingV2Key = "messagingBundleIDsV2"
    private static let messagingV1Key = "messagingBundleIDs"

    @Published private(set) var bundleIDs: [String]

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "kept-app-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Already on V3.
        if defaults.object(forKey: Self.defaultsKey) != nil {
            let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
            bundleIDs = Self.cleaned(stored)
            if bundleIDs != stored { persist() }
            seedFinderOnce()
            return
        }

        // First migration to V3. Messaging apps now join kept so they stay visible
        // after exit under the unified model. Frozen legacy keys (V2 / V1 / pinned)
        // are left untouched for a clean code rollback.
        let messaging = Self.authoritativeMessagingNames(defaults)
        let seed: [String]
        if defaults.object(forKey: Self.previousDefaultsKey) != nil {
            // Kept V2 exists: keep its order first, messaging appended.
            let v2 = defaults.stringArray(forKey: Self.previousDefaultsKey) ?? []
            seed = v2 + messaging
        } else {
            // No kept V2 (upgrading straight past it): fold V1 + pinned + drawer + messaging.
            let v1 = defaults.stringArray(forKey: Self.v1Key) ?? []
            let legacy = defaults.stringArray(forKey: Self.legacyKey) ?? []
            let drawer = defaults.stringArray(forKey: Self.drawerKey) ?? []
            seed = v1 + legacy + drawer + messaging
        }
        bundleIDs = Self.cleaned(seed)
        persist() // Empty is intentional: V3 key existence is the migration marker.
        seedFinderOnce()
        logger.info("initialized keptAppBundleIDsV3 with \(self.bundleIDs.count) entries")
    }

    /// 访达默认勾上，只补一次（owner 2026-08-20）。老用户升级后观感完全不变；
    /// 之后用户自己取消勾选，标记已为真，不会被下次启动重新打开。
    /// 追加到**尾部**：既有 kept 顺序与 `StripOrderStore` 的跨机器重启排名都不受扰动。
    private func seedFinderOnce() {
        guard !defaults.bool(forKey: Self.finderSeedKey) else { return }
        defaults.set(true, forKey: Self.finderSeedKey)
        guard !contains(FinderTaskbarPolicy.bundleID) else { return }
        add(FinderTaskbarPolicy.bundleID)
        logger.info("seeded Finder into keptAppBundleIDsV3 (one-shot)")
    }

    /// The native Dock's all-apps entry on macOS 26+ (Apps, a Spotlight panel). Launchpad
    /// (macOS 12-15, `com.apple.launchpad.launcher`) is deliberately not seeded: it is a
    /// full-screen page that covers the taskbar and brings the native Dock back, and its icons
    /// cannot be dragged onto the taskbar — do not add it back as a fallback.
    static let systemAppLauncherBundleID = "com.apple.apps.launcher"

    /// A fresh install keeps the system's all-apps entry right after Finder, as the native Dock
    /// does. Fresh is decided by `InstallLineage` only (AGENTS.md): upgraders never get it, so
    /// unlike Finder there is no seed marker — an un-check is simply never undone.
    func seedSystemAppLauncherForFreshInstall(lineage: InstallLineage, isInstalled: (String) -> Bool) {
        guard lineage == .pristine, isInstalled(Self.systemAppLauncherBundleID) else { return }
        add(Self.systemAppLauncherBundleID)
        logger.info("seeded \(Self.systemAppLauncherBundleID, privacy: .public) into keptAppBundleIDsV3 (fresh install)")
    }

    /// Authoritative messaging names for the kept-V3 seed, independent of store
    /// init order: if the messaging V2 key exists (even an explicit empty array)
    /// read only it; otherwise fall back to the legacy messaging key. Never union.
    private static func authoritativeMessagingNames(_ defaults: UserDefaults) -> [String] {
        if defaults.object(forKey: messagingV2Key) != nil {
            return defaults.stringArray(forKey: messagingV2Key) ?? []
        }
        return defaults.stringArray(forKey: messagingV1Key) ?? []
    }

    /// 只剩非空判定：访达 2026-08-20 起也允许 kept，此处不再有例外名单。
    static func canKeep(_ bundleID: String) -> Bool {
        normalized(bundleID) != nil
    }

    func canKeep(_ bundleID: String) -> Bool {
        Self.canKeep(bundleID)
    }

    func contains(_ bundleID: String) -> Bool {
        guard let normalized = Self.normalized(bundleID) else { return false }
        return bundleIDs.contains(normalized)
    }

    func add(_ bundleID: String) {
        guard Self.canKeep(bundleID),
              let normalized = Self.normalized(bundleID),
              !bundleIDs.contains(normalized) else { return }
        bundleIDs.append(normalized)
        persist()
    }

    func remove(_ bundleID: String) {
        guard let normalized = Self.normalized(bundleID) else { return }
        let previousCount = bundleIDs.count
        bundleIDs.removeAll { $0 == normalized }
        if bundleIDs.count != previousCount {
            persist()
        }
    }

    private static func cleaned(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for bundleID in bundleIDs {
            guard canKeep(bundleID),
                  let normalized = normalized(bundleID),
                  seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func normalized(_ bundleID: String) -> String? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func persist() {
        defaults.set(bundleIDs, forKey: Self.defaultsKey)
    }
}
