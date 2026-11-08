import AppKit
import Combine
import Foundation
import XCTest

private final class OriginMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var memory: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { memory[key] }
    override func integer(forKey key: String) -> Int { memory[key] as? Int ?? 0 }
    override func stringArray(forKey key: String) -> [String]? { memory[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { memory[key] as? [String: Any] }
    override func set(_ value: Any?, forKey key: String) { memory[key] = value }
}

@MainActor
private final class OriginInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }
    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() {}
    func stop() {}
}

@MainActor
private final class OriginPopup: TaskbarPopupPresenting {
    var panel: NSPanel? { nil }
    var isPresented: Bool { false }
    var onPresent: ((NSPanel) -> Void)?
    var onDismiss: (() -> Void)?
    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {}
    func focusForKeyboard() {}
    func dismiss() {}
}

@MainActor
private final class OriginContextMenu: TaskbarContextMenuPresenting {
    var visibilityChanged: ((Bool) -> Void)?
    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) {}
    func dismiss() {}
}

@MainActor
final class TaskbarResourceOriginTests: XCTestCase {
    func testSeparateInstallationsWithTheSameBundleIDKeepTheirOwnNamesAndIcons() async throws {
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = try application(at: directory.appendingPathComponent("Alpha.app"), name: "Alpha")
        let beta = try application(at: directory.appendingPathComponent("Beta.app"), name: "Beta")
        let records = [("alpha", alpha), ("beta", beta)].enumerated().map { index, entry in
            WindowRecord(id: WindowID(rawValue: entry.0), appID: AppID(rawValue: "review.shared"),
                pid: -42000 - Int32(index), bundleIdentifier: "review.shared", title: entry.0,
                bounds: nil, status: .inactive, cgWindowID: UInt32(index + 1), displayUUID: "fixture",
                applicationOrigin: ApplicationOrigin(bundleURL: entry.1))
        }
        let inventory = OriginInventory(DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), orderedWindowIDs: records.map(\.id)))
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false, directoryURL: directory,
            maxFileSize: 1_048_576, archiveCount: 0))
        let runtime = AppRuntime(inventoryLog: log, tracker: inventory)
        let ordering = StripOrderStore(defaults: OriginMemoryDefaults(), bootTimeProvider: { 1 }, inventoryLog: log)
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["fixture"], attributionTable: .init(displays: [
                .init(uuid: "fixture", cgFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ], primaryUUID: "fixture")))
        let spaces = TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0)
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 1920, height: 32),
            popup: OriginPopup(), contextMenu: OriginContextMenu())
        var renderedPaths: [String] = []
        let icons = AppIconResolver(notifications: NotificationCenter(), applicationURL: { _ in alpha },
            imageForFile: { path in
                renderedPaths.append(path)
                return NSImage(size: NSSize(width: 32, height: 32))
            }, fallbackImage: { NSImage(size: NSSize(width: 32, height: 32)) })
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
            topology: topology, spaces: spaces, displayUUID: "fixture", backgroundMenu: { _, _ in },
            popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in }, icons: icons)
        runtime.start()
        defer { runtime.stop(); withExtendedLifetime(presenter) {} }
        let deadline = ContinuousClock.now + .seconds(2)
        while view.taskbarContent.groups.count != 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(Set(view.taskbarContent.groups.map(\.name)), ["Alpha", "Beta"])
        XCTAssertEqual(Set(renderedPaths), [alpha.path, beta.path])
        XCTAssertNil(view.window)
    }

    private func application(at url: URL, name: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "review.shared", "CFBundleName": name, "CFBundleDisplayName": name,
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func testOriginScopedNamesAreCachedSeparatelyAndInvalidatedTogether() {
        let cache = AppDisplayNameCache()
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Alpha.app") { "Alpha" }, "Alpha")
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Beta.app") { "Beta" }, "Beta")
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Alpha.app") {
            XCTFail("The unchanged origin must use its cached name")
            return "Unexpected"
        }, "Alpha")
        cache.invalidate(bundleID: "shared")
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Alpha.app") { "New Alpha" }, "New Alpha")
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Beta.app") { "New Beta" }, "New Beta")
    }

    func testOriginScopedNameEntriesRemainBounded() {
        let cache = AppDisplayNameCache()
        for index in 0...512 {
            _ = cache.value(for: "shared", bundlePath: "/fixture/Variant\(index).app") { "Variant \(index)" }
        }
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Variant0.app") { "Reloaded" }, "Reloaded")
        XCTAssertEqual(cache.value(for: "shared", bundlePath: "/fixture/Variant512.app") {
            XCTFail("A recent origin must still be cached")
            return "Unexpected"
        }, "Variant 512")
    }

    func testChangedIconInvalidatesOnlyItsInstallation() async throws {
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = try application(at: directory.appendingPathComponent("Alpha.app"), name: "Alpha")
        let beta = try application(at: directory.appendingPathComponent("Beta.app"), name: "Beta")
        let alphaOrigin = try XCTUnwrap(ApplicationOrigin(bundleURL: alpha))
        let betaOrigin = try XCTUnwrap(ApplicationOrigin(bundleURL: beta))
        let center = NotificationCenter()
        let probe = IconStampReadProbe()
        var paths: [String] = []
        let resolver = AppIconResolver(notifications: center, applicationURL: { _ in alpha },
            imageForFile: { path in paths.append(path); return NSImage(size: NSSize(width: 32, height: 32)) },
            fallbackImage: { NSImage(size: NSSize(width: 32, height: 32)) }, stampAtPath: { probe.read($0) })
        _ = resolver.icon(for: "shared", origin: alphaOrigin)
        _ = resolver.icon(for: "shared", origin: betaOrigin)
        await waitForIconStampReads(2, probe: probe)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await waitForIconStampReads(4, probe: probe)
        var invalidated = false
        let subscription = resolver.changes.sink { invalidated = true }
        defer { subscription.cancel() }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: alpha.appendingPathComponent("Contents/Info.plist").path)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while !invalidated, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(invalidated)
        _ = resolver.icon(for: "shared", origin: alphaOrigin)
        _ = resolver.icon(for: "shared", origin: betaOrigin)
        XCTAssertEqual(paths, [alpha.path, beta.path, alpha.path])
    }
}
