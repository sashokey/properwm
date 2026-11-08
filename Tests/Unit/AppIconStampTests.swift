import AppKit
import Combine
import XCTest

final class AppIconStampTests: XCTestCase {
    private var directory: URL!
    private var app: URL!
    private var infoPlist: URL!

    override func setUpWithError() throws {
        directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app = directory.appendingPathComponent("X.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        infoPlist = contents.appendingPathComponent("Info.plist")
        try writeInfoPlist(version: "1")
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testUnchangedDirectoryHasEqualStamps() throws {
        let first = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertTrue(first.infoPlistExists)
        XCTAssertEqual(first, AppIconStamp.stamp(atPath: app.path))
    }

    func testCreatingAndRemovingCustomIconChangesStamp() throws {
        let original = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        let icon = app.appendingPathComponent("Icon\r")
        // Keep the mutations on distinct filesystem clock ticks.
        Thread.sleep(forTimeInterval: 0.01)
        try Data([1, 2, 3]).write(to: icon)
        let customized = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertNotEqual(original, customized)
        XCTAssertEqual(original.bundleInode, customized.bundleInode)

        Thread.sleep(forTimeInterval: 0.01)
        try FileManager.default.removeItem(at: icon)
        let restored = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertNotEqual(customized, restored)
        XCTAssertEqual(customized.bundleInode, restored.bundleInode)
    }

    func testRewritingInfoPlistChangesStamp() throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: infoPlist.path
        )
        let original = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        try writeInfoPlist(version: "2")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)], ofItemAtPath: infoPlist.path
        )
        let updated = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertNotEqual(original, updated)
        XCTAssertEqual(original.bundleInode, updated.bundleInode)
        XCTAssertEqual(original.bundleChangeSeconds, updated.bundleChangeSeconds)
        XCTAssertEqual(original.bundleChangeNanoseconds, updated.bundleChangeNanoseconds)
    }

    func testMissingDirectoryHasNoStamp() {
        XCTAssertNil(AppIconStamp.stamp(atPath: directory.appendingPathComponent("Missing.app").path))
    }

    private func writeInfoPlist(version: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.app-icon-stamp", "CFBundleVersion": version],
            format: .xml, options: 0
        )
        try data.write(to: infoPlist)
    }
}

@MainActor
final class AppIconResolverTests: XCTestCase {
    func testUnresolvedIconRetriesOnApplicationEventsAndNotEveryRender() {
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            let notifications = NotificationCenter()
            var url: URL?
            var lookups = 0
            var renderedPaths: [String] = []
            let resolver = AppIconResolver(notifications: notifications, applicationURL: { _ in
                lookups += 1
                return url
            }, imageForFile: { path in renderedPaths.append(path); return NSImage(size: .init(width: 32, height: 32)) },
                fallbackImage: { NSImage(size: .init(width: 32, height: 32)) })
            var updates = 0
            let subscription = resolver.changes.sink { updates += 1 }
            _ = resolver.icon(for: "test.icon")
            _ = resolver.icon(for: "test.icon")
            XCTAssertEqual(lookups, 1)
            url = URL(fileURLWithPath: "/fixture/Test.app")
            notifications.post(name: notification, object: nil)
            XCTAssertEqual(updates, 1)
            _ = resolver.icon(for: "test.icon")
            XCTAssertEqual(lookups, 2)
            XCTAssertEqual(renderedPaths, ["/fixture/Test.app"])
            _ = resolver.icon(for: "test.icon")
            XCTAssertEqual(lookups, 2)
            withExtendedLifetime(subscription) {}
        }
    }

    func testApplicationNotificationDoesNotRetainResolver() {
        let notifications = NotificationCenter()
        var resolver: AppIconResolver? = AppIconResolver(notifications: notifications, applicationURL: { _ in nil },
            fallbackImage: { NSImage(size: .init(width: 32, height: 32)) })
        weak var weakResolver = resolver
        _ = resolver?.icon(for: "test.icon")
        resolver = nil
        notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertNil(weakResolver)
    }
}

final class IconStampReadProbe: @unchecked Sendable {
    struct Read: Sendable {
        let path: String
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private let gates: [Int: DispatchSemaphore]
    private var reads: [Read] = []
    private var timeouts = 0

    init(blocking reads: [Int] = []) {
        gates = Dictionary(uniqueKeysWithValues: reads.map { ($0, DispatchSemaphore(value: 0)) })
    }

    func read(_ path: String) -> AppIconStamp? {
        let stamp = AppIconStamp.stamp(atPath: path)
        lock.lock()
        reads.append(Read(path: path, onMainThread: Thread.isMainThread))
        let gate = gates[reads.count]
        lock.unlock()
        if let gate, gate.wait(timeout: .now() + 5) == .timedOut {
            lock.lock()
            timeouts += 1
            lock.unlock()
        }
        return stamp
    }

    func release(_ read: Int) { gates[read]?.signal() }

    var observations: [Read] {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var timeoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return timeouts
    }
}

@MainActor
func waitForIconStampReads(_ count: Int, probe: IconStampReadProbe,
                          file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while probe.observations.count < count, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertGreaterThanOrEqual(probe.observations.count, count, file: file, line: line)
    XCTAssertEqual(probe.timeoutCount, 0, file: file, line: line)
}

@MainActor
extension AppIconResolverTests {
    func testColdRenderStampsOffMainAndPreservesCachedImage() async throws {
        let fixture = try iconFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let origin = try XCTUnwrap(ApplicationOrigin(bundleURL: fixture.app))
        let center = NotificationCenter()
        let probe = IconStampReadProbe(blocking: [1, 2])
        defer { probe.release(1); probe.release(2) }
        var imageReads = 0
        var changes = 0
        let resolver = AppIconResolver(notifications: center, applicationURL: { _ in nil }, imageForFile: { _ in
            XCTAssertTrue(Thread.isMainThread)
            imageReads += 1
            return NSImage(size: NSSize(width: 32, height: 32))
        }, stampAtPath: { probe.read($0) })
        let subscription = resolver.changes.sink { changes += 1 }
        defer { subscription.cancel() }
        let first = resolver.icon(for: "fixture.icon", origin: origin)
        for _ in 0..<100 {
            XCTAssertTrue(first === resolver.icon(for: "fixture.icon", origin: origin))
        }
        await waitForIconStampReads(1, probe: probe)
        XCTAssertEqual(probe.observations.map(\.onMainThread), [false])
        XCTAssertEqual(imageReads, 1)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        probe.release(1)
        await waitForIconStampReads(2, probe: probe)
        XCTAssertTrue(first === resolver.icon(for: "fixture.icon", origin: origin))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(probe.observations.map(\.path), [fixture.app.path, fixture.app.path])
        XCTAssertEqual(probe.observations.map(\.onMainThread), [false, false])
        XCTAssertEqual(imageReads, 1)
    }

    func testInitialMissingStampRemainsCachedUntilPathAppears() async throws {
        let fixture = try iconFixture(createApplication: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let origin = try XCTUnwrap(ApplicationOrigin(bundleURL: fixture.app))
        let center = NotificationCenter()
        let probe = IconStampReadProbe(blocking: [1, 2])
        defer { probe.release(1); probe.release(2) }
        var imageReads = 0
        let resolver = AppIconResolver(notifications: center, applicationURL: { _ in nil }, imageForFile: { _ in
            imageReads += 1
            return NSImage(size: NSSize(width: 32, height: 32))
        }, stampAtPath: { probe.read($0) })
        let changed = expectation(description: "The appeared application invalidates the known missing stamp")
        var changes = 0
        let subscription = resolver.changes.sink { changes += 1; changed.fulfill() }
        defer { subscription.cancel() }
        let first = resolver.icon(for: "fixture.missing", origin: origin)
        await waitForIconStampReads(1, probe: probe)
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        probe.release(1)
        await waitForIconStampReads(2, probe: probe)
        XCTAssertTrue(first === resolver.icon(for: "fixture.missing", origin: origin))
        XCTAssertEqual(changes, 0)
        try createIconApplication(at: fixture.app)
        probe.release(2)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(first === resolver.icon(for: "fixture.missing", origin: origin))
        XCTAssertEqual(imageReads, 2)
        XCTAssertTrue(probe.observations.allSatisfy { !$0.onMainThread })
    }

    func testNewColdIconDoesNotRestampInitializedIcons() async throws {
        let fixture = try iconFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let beta = fixture.directory.appendingPathComponent("Beta.app")
        try createIconApplication(at: beta)
        let alphaOrigin = try XCTUnwrap(ApplicationOrigin(bundleURL: fixture.app))
        let betaOrigin = try XCTUnwrap(ApplicationOrigin(bundleURL: beta))
        let center = NotificationCenter()
        let probe = IconStampReadProbe(blocking: [1, 2, 3])
        defer { probe.release(1); probe.release(2); probe.release(3) }
        let resolver = AppIconResolver(notifications: center, applicationURL: { _ in nil },
            imageForFile: { _ in NSImage(size: NSSize(width: 32, height: 32)) }, stampAtPath: { probe.read($0) })
        let alpha = resolver.icon(for: "fixture.shared", origin: alphaOrigin)
        await waitForIconStampReads(1, probe: probe)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        probe.release(1)
        await waitForIconStampReads(2, probe: probe)
        _ = resolver.icon(for: "fixture.shared", origin: betaOrigin)
        probe.release(2)
        await waitForIconStampReads(3, probe: probe)
        XCTAssertEqual(probe.observations.map(\.path), [fixture.app.path, fixture.app.path, beta.path])
        XCTAssertTrue(alpha === resolver.icon(for: "fixture.shared", origin: alphaOrigin))
        XCTAssertTrue(probe.observations.allSatisfy { !$0.onMainThread })
    }

    func testDelayedInitialResultDoesNotStampSamePathCacheReplacement() async throws {
        let fixture = try iconFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let origin = try XCTUnwrap(ApplicationOrigin(bundleURL: fixture.app))
        let probe = IconStampReadProbe(blocking: [1, 2])
        defer { probe.release(1); probe.release(2) }
        var imageReads = 0
        var changes = 0
        let resolver = AppIconResolver(notifications: NotificationCenter(), applicationURL: { _ in nil }, imageForFile: { _ in
            imageReads += 1
            return NSImage(size: NSSize(width: 32, height: 32))
        }, fallbackImage: { NSImage(size: NSSize(width: 32, height: 32)) }, stampAtPath: { probe.read($0) })
        let subscription = resolver.changes.sink { changes += 1 }
        defer { subscription.cancel() }
        let first = resolver.icon(for: "fixture.icon", origin: origin)
        await waitForIconStampReads(1, probe: probe)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)],
            ofItemAtPath: fixture.app.appendingPathComponent("Contents/Info.plist").path)
        for index in 0..<512 { _ = resolver.icon(for: "fixture.eviction.\(index)") }
        let replacement = resolver.icon(for: "fixture.icon", origin: origin)
        XCTAssertFalse(first === replacement)
        probe.release(1)
        await waitForIconStampReads(2, probe: probe)
        XCTAssertEqual(probe.observations.map(\.path), [fixture.app.path, fixture.app.path])
        XCTAssertTrue(replacement === resolver.icon(for: "fixture.icon", origin: origin))
        XCTAssertEqual(imageReads, 2)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(probe.observations.allSatisfy { !$0.onMainThread })
    }

    private func iconFixture(createApplication: Bool = true) throws -> (directory: URL, app: URL) {
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = directory.appendingPathComponent("Fixture.app")
        if createApplication { try createIconApplication(at: app) }
        return (directory, app)
    }

    private func createIconApplication(at app: URL) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: contents.appendingPathComponent("Info.plist").path)
    }
}

@MainActor
final class AppIconFreshnessCheckerTests: XCTestCase {
    func testInitialRequestsCoalesceWithoutUpgradingToFullScan() async throws {
        try await checkCoalescing(fullFollowUp: false)
    }

    func testApplicationEventPreservesFullScanWhenInitialRequestsAreCoalesced() async throws {
        try await checkCoalescing(fullFollowUp: true)
    }

    private func checkCoalescing(fullFollowUp: Bool) async throws {
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = IconStampReadProbe(blocking: [1])
        defer { probe.release(1) }
        var snapshots: [Bool] = []
        var callbackOnMain: [Bool] = []
        var generations: [UInt64] = []
        let completed = expectation(description: "The checker completes the original and one coalesced request")
        completed.expectedFulfillmentCount = 2
        completed.assertForOverFulfill = true
        let checker = AppIconFreshnessChecker(snapshot: { onlyUninitialized in
            snapshots.append(onlyUninitialized)
            return [.init(key: "fixture", path: directory.path, generation: 17, stamp: nil)]
        }, didCheck: { entries in
            callbackOnMain.append(Thread.isMainThread)
            generations += entries.map(\.generation)
            XCTAssertNotNil(entries.first?.stamp)
            completed.fulfill()
        }, stampAtPath: { probe.read($0) })
        checker.requestCheck(onlyUninitialized: true)
        await waitForIconStampReads(1, probe: probe)
        for _ in 0..<100 { checker.requestCheck(onlyUninitialized: true) }
        if fullFollowUp { checker.requestCheck() }
        for _ in 0..<100 { checker.requestCheck(onlyUninitialized: true) }
        probe.release(1)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(snapshots, [true, !fullFollowUp])
        XCTAssertEqual(probe.observations.count, 2)
        XCTAssertEqual(callbackOnMain, [true, true])
        XCTAssertEqual(generations, [17, 17])
        XCTAssertTrue(probe.observations.allSatisfy { !$0.onMainThread })
    }
}
