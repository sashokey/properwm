import AppKit
import Combine
import Foundation
import XCTest

private final class CrossDisplayMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var memory: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { memory[defaultName] }
    override func integer(forKey defaultName: String) -> Int { memory[defaultName] as? Int ?? 0 }
    override func stringArray(forKey defaultName: String) -> [String]? { memory[defaultName] as? [String] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { memory[defaultName] as? [String: Any] }
    override func set(_ value: Any?, forKey defaultName: String) { memory[defaultName] = value }
}

@MainActor
private final class CrossDisplayInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }

    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() {}
    func stop() {}
}

@MainActor
private final class CrossDisplayPopup: TaskbarPopupPresenting {
    var panel: NSPanel? { nil }
    var isPresented: Bool { false }
    var onPresent: ((NSPanel) -> Void)?
    var onDismiss: (() -> Void)?

    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {}
    func focusForKeyboard() {}
    func dismiss() { onDismiss?() }
}

@MainActor
private final class CrossDisplayContextMenu: TaskbarContextMenuPresenting {
    var visibilityChanged: ((Bool) -> Void)?
    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) {}
    func dismiss() {}
}

@MainActor
final class PresenterCrossDisplayRegressionTests: XCTestCase {
    func testHiddenPresenterDoesNotReloadButtonsForAnotherDisplaysTitleChanges() async {
        let inventory = CrossDisplayInventory(makeSnapshot(remoteTitleVersion: 0))
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            maxFileSize: 1_048_576, archiveCount: 0))
        let runtime = AppRuntime(inventoryLog: log, tracker: inventory)
        let ordering = StripOrderStore(defaults: CrossDisplayMemoryDefaults(), bootTimeProvider: { 1 }, inventoryLog: log)
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 2,
            identifiedDisplayUUIDs: ["fixture", "remote"], attributionTable: .init(displays: [
                .init(uuid: "fixture", cgFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                .init(uuid: "remote", cgFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ], primaryUUID: "fixture")))
        let spaces = TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0)
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 1920, height: 32),
            popup: CrossDisplayPopup(), contextMenu: CrossDisplayContextMenu())
        let icons = AppIconResolver(notifications: NotificationCenter(), applicationURL: { _ in nil },
            fallbackImage: { NSImage(size: NSSize(width: 32, height: 32)) })
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
            topology: topology, spaces: spaces, displayUUID: "fixture", backgroundMenu: { _, _ in },
            popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in }, icons: icons)
        var iconRequests = 0
        view.taskbarContent.iconProvider = { _ in iconRequests += 1; return nil }
        runtime.start()
        defer {
            view.taskbarContent.prepareForHiding()
            runtime.stop()
            withExtendedLifetime(presenter) {}
        }
        await waitUntil { view.taskbarContent.buttonViews.count == 10 }
        XCTAssertNil(view.window)
        let originalGroups = view.taskbarContent.groups
        let originalLayout = view.taskbarContent.layoutResult
        let originalLabels = view.taskbarContent.buttonViews.mapValues(\.title)
        view.isHidden = true
        view.taskbarContent.prepareForHiding()
        await Task.yield()
        iconRequests = 0
        for version in 1...5 {
            inventory.values.send(makeSnapshot(remoteTitleVersion: version))
            await waitUntil {
                runtime.snapshot.windows[WindowID(rawValue: "remote-window")]?.title == "Remote progress \(version)"
            }
            await flushPresenterQueue()
            XCTAssertEqual(view.taskbarContent.groups, originalGroups)
            XCTAssertEqual(view.taskbarContent.layoutResult, originalLayout)
            XCTAssertEqual(view.taskbarContent.buttonViews.mapValues(\.title), originalLabels)
        }
        XCTAssertTrue(view.isHidden)
        XCTAssertNil(view.window)
        print("Presenter churn repro: remote-title-only snapshots=5, local metadata unchanged=true, buttons=10, hidden=true, window=nil, iconProvider calls=\(iconRequests)")
        XCTAssertEqual(iconRequests, 0, "Five remote-display title snapshots reconfigured all ten hidden local buttons despite identical local groups, labels and layout")
    }

    private func flushPresenterQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func makeSnapshot(remoteTitleVersion: Int) -> DockSnapshot {
        var records = (0..<10).map { index in
            WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "fixture"),
                pid: 2_000_000_000, bundleIdentifier: nil, title: "Document \(index)",
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                status: index == 0 ? .active : .inactive, cgWindowID: UInt32(index + 1),
                groupID: "window-\(index)", displayUUID: "fixture")
        }
        records.append(WindowRecord(id: WindowID(rawValue: "remote-window"),
            appID: AppID(rawValue: "remote-app"), pid: 2_000_000_001, bundleIdentifier: nil,
            title: "Remote progress \(remoteTitleVersion)",
            bounds: CGRect(x: 1920, y: 0, width: 800, height: 600), status: .inactive,
            cgWindowID: 100, groupID: "remote-window", displayUUID: "remote"))
        return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id))
    }
}
