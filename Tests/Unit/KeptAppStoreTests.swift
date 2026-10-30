import XCTest
@testable import macos_dock_cc_v2

@MainActor
final class KeptAppStoreTests: XCTestCase {

    /// 默认把访达播种标记先置真，让迁移用例只考察迁移本身；播种行为由专门的用例覆盖。
    private func makeDefaults(finderSeeded: Bool = true) -> UserDefaults {
        let suite = "test-kept-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if finderSeeded { defaults.set(true, forKey: KeptAppStore.finderSeedKey) }
        return defaults
    }

    func testFreshInstallPersistsEmptyV3MigrationMarker() {
        let defaults = makeDefaults()
        let store = KeptAppStore(defaults: defaults)
        XCTAssertTrue(store.bundleIDs.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey), [])
    }

    // MARK: - 访达一次性播种（owner 2026-08-20：默认勾上）

    func testFreshInstallSeedsFinderAsKept() {
        let defaults = makeDefaults(finderSeeded: false)
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, [FinderTaskbarPolicy.bundleID])
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey),
                       [FinderTaskbarPolicy.bundleID])
        XCTAssertTrue(defaults.bool(forKey: KeptAppStore.finderSeedKey))
    }

    func testExistingUserGetsFinderAppendedAtTail() {
        // 老用户的 V3 早就写好了，播种必须走独立标记键，且追加到尾部不扰动既有顺序。
        let defaults = makeDefaults(finderSeeded: false)
        defaults.set(["com.example.first", "com.example.second"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs,
                       ["com.example.first", "com.example.second", FinderTaskbarPolicy.bundleID])
    }

    func testUncheckedFinderIsNotReseededOnNextLaunch() {
        let defaults = makeDefaults(finderSeeded: false)
        let first = KeptAppStore(defaults: defaults)
        first.remove(FinderTaskbarPolicy.bundleID)     // 用户右键取消勾选
        let second = KeptAppStore(defaults: defaults)  // 下次启动
        XCTAssertFalse(second.contains(FinderTaskbarPolicy.bundleID))
    }

    // MARK: - System all-apps entry (owner 2026-10-07: fresh installs only)

    func testFreshInstallKeepsAppsRightAfterFinder() {
        let store = KeptAppStore(defaults: makeDefaults(finderSeeded: false))
        store.seedSystemAppLauncherForFreshInstall(lineage: .pristine) { _ in true }
        XCTAssertEqual(store.bundleIDs, [FinderTaskbarPolicy.bundleID, "com.apple.apps.launcher"])
    }

    func testLaunchpadIsNeverSeededBeforeMacOS26() {
        let store = KeptAppStore(defaults: makeDefaults())
        store.seedSystemAppLauncherForFreshInstall(lineage: .pristine) { $0 == "com.apple.launchpad.launcher" }
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }

    func testUpgraderNeverGetsSystemAppLauncher() {
        let defaults = makeDefaults()
        defaults.set(["com.example.app"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        store.seedSystemAppLauncherForFreshInstall(lineage: .priorUse) { _ in true }
        XCTAssertEqual(store.bundleIDs, ["com.example.app"])
    }

    func testNoInstalledLauncherSeedsNothing() {
        let store = KeptAppStore(defaults: makeDefaults())
        store.seedSystemAppLauncherForFreshInstall(lineage: .pristine) { _ in false }
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }

    func testLoadsFromV3Key() {
        let defaults = makeDefaults()
        defaults.set(["com.example.app"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.example.app"])
    }

    func testCanKeepAcceptsFinderAndRejectsBlank() {
        let store = KeptAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.canKeep(FinderTaskbarPolicy.bundleID))
        XCTAssertFalse(store.canKeep("   "))
    }

    func testAddAcceptsFinder() {
        let defaults = makeDefaults()
        let store = KeptAppStore(defaults: defaults)
        store.add(FinderTaskbarPolicy.bundleID)
        XCTAssertEqual(store.bundleIDs, [FinderTaskbarPolicy.bundleID])
    }

    func testAddAndContains() {
        let defaults = makeDefaults()
        let store = KeptAppStore(defaults: defaults)
        store.add("com.example.app")
        XCTAssertTrue(store.contains("com.example.app"))
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey), ["com.example.app"])
    }

    func testRemove() {
        let defaults = makeDefaults()
        defaults.set(["com.example.first", "com.example.second"], forKey: KeptAppStore.defaultsKey)
        let store = KeptAppStore(defaults: defaults)
        store.remove("com.example.first")
        XCTAssertFalse(store.contains("com.example.first"))
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey), ["com.example.second"])
    }

    // MARK: - V3 migration

    func testMigratesFromV2PlusMessaging() {
        let defaults = makeDefaults()
        defaults.set(["com.example.kept"], forKey: KeptAppStore.previousDefaultsKey) // kept V2
        defaults.set(["com.chat.app"], forKey: "messagingBundleIDsV2")               // 权威消息名单
        defaults.set(["com.ignored.pinned"], forKey: "pinnedAppBundleIDs")           // 有 V2 时 pinned/drawer 被忽略
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.example.kept", "com.chat.app"])
        XCTAssertEqual(defaults.stringArray(forKey: KeptAppStore.defaultsKey),
                       ["com.example.kept", "com.chat.app"])
    }

    func testMessagingV2KeyIsAuthoritativeEvenWhenEmpty() {
        // messaging V2 存在但空 → 权威为空，禁止回退旧 messaging 键求并集。
        let defaults = makeDefaults()
        defaults.set(["com.example.kept"], forKey: KeptAppStore.previousDefaultsKey)
        defaults.set([String](), forKey: "messagingBundleIDsV2")
        defaults.set(["com.legacy.chat"], forKey: "messagingBundleIDs")
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.example.kept"])
    }

    func testMigratesStraightPastV2FoldsV1PinnedDrawerMessaging() {
        // 无 kept V2 → 折叠 V1 + pinned + drawer + messaging（messaging 现在并入）。
        let defaults = makeDefaults()
        defaults.set(["com.v1.kept"], forKey: "keptAppBundleIDs")     // V1
        defaults.set(["com.pin.app"], forKey: "pinnedAppBundleIDs")
        defaults.set(["com.drawer.app", "com.chat.app"], forKey: "drawerBundleIDs")
        defaults.set(["com.chat.app"], forKey: "messagingBundleIDs")  // 无 V2，旧 messaging 键权威
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs,
                       ["com.v1.kept", "com.pin.app", "com.drawer.app", "com.chat.app"])
    }

    func testMigrationKeepsFinderAndDeduplicates() {
        let defaults = makeDefaults()
        defaults.set(["com.dup", "com.dup", FinderTaskbarPolicy.bundleID], forKey: "keptAppBundleIDs")
        let store = KeptAppStore(defaults: defaults)
        XCTAssertEqual(store.bundleIDs, ["com.dup", FinderTaskbarPolicy.bundleID])
    }

    func testExistingEmptyV3KeyPreventsRemigration() {
        let defaults = makeDefaults()
        defaults.set([String](), forKey: KeptAppStore.defaultsKey)
        defaults.set(["com.example.kept"], forKey: KeptAppStore.previousDefaultsKey)
        defaults.set(["com.chat.app"], forKey: "messagingBundleIDsV2")
        let store = KeptAppStore(defaults: defaults)
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }

    func testMigrationFreezesLegacyKeysReadOnly() {
        // V3 迁移不得删除/覆写冻结旧键（干净回滚）。
        let defaults = makeDefaults()
        defaults.set(["com.v1.kept"], forKey: "keptAppBundleIDs")
        defaults.set(["com.pin.app"], forKey: "pinnedAppBundleIDs")
        _ = KeptAppStore(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "keptAppBundleIDs"), ["com.v1.kept"])
        XCTAssertEqual(defaults.stringArray(forKey: "pinnedAppBundleIDs"), ["com.pin.app"])
    }
}
