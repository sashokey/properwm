import AppKit
import Combine
import Synchronization
import XCTest

@MainActor
private final class SpaceInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }
    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() {}
    func stop() {}
}

@MainActor
final class TaskbarSpaceStoreTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func inventory() -> DockSnapshot {
        let records = (1...2).map { index in
            WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "app-\(index)"), pid: Int32(40 + index),
                bundleIdentifier: "test.space.\(index)", title: "Window \(index)", bounds: nil,
                status: .inactive, cgWindowID: UInt32(index), groupID: "window-\(index)", displayUUID: "left")
        }
        return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), orderedWindowIDs: records.map(\.id))
    }

    func testSpaceNotificationsRefreshPresentationWithoutLosingInventoryOrManualOrder() async {
        let fixture = SpaceInventory(inventory())
        let runtime = AppRuntime(tracker: fixture, isAccessibilityTrusted: { true })
        let center = NotificationCenter()
        let current = Mutex(1)
        let store = TaskbarSpaceStore(read: { requests in
            WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: current.withLock { $0 })],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([Int($0.identity.windowID)])) }))
        }, notifications: center, pollInterval: 0)
        let domain = "ProperWM.SpaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let topology = DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["left"], attributionTable: .empty))
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
            topology: topology, spaces: store, displayUUID: nil,
            backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenter) {} }
        await waitUntil { store.snapshot.memberships.count == 2 && view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["window-1"] }
        ordering.reorderGroup("test.space.2", relativeTo: "test.space.1", after: false, current: ["window-1", "window-2"])
        await waitUntil { ordering.liveOrder == ["window-2", "window-1"] }
        current.withLock { $0 = 2 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["window-2"] }
        XCTAssertEqual(runtime.snapshot.windows.count, 2)
        XCTAssertEqual(ordering.liveOrder, ["window-2", "window-1"])
        current.withLock { $0 = 1 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["window-1"] }
        XCTAssertEqual(ordering.liveOrder, ["window-2", "window-1"])
        XCTAssertNil(view.window)
    }

    func testCoalescedReadsRunOffMainAndStopRejectsLateResults() async {
        let calls = Mutex<[Bool]>([])
        let gate = DispatchSemaphore(value: 0)
        let store = TaskbarSpaceStore(read: { _ in
            calls.withLock { $0.append(Thread.isMainThread) }
            _ = gate.wait(timeout: .now() + 2)
            return WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1)])
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: Just(DockSnapshot.empty).eraseToAnyPublisher())
        await waitUntil { calls.withLock { $0.count } == 1 }
        for _ in 0..<20 { store.refresh() }
        gate.signal()
        await waitUntil { calls.withLock { $0.count } == 2 }
        XCTAssertTrue(store.snapshot.layouts.isEmpty)
        let pending = store.pendingWorkForTesting
        store.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertTrue(store.snapshot.layouts.isEmpty)
        XCTAssertFalse(calls.withLock { $0.contains(true) })
        store.refresh()
        XCTAssertEqual(calls.withLock { $0.count }, 2)
    }

    func testFailedReadPreservesLastConfirmedSpaceAndRecoveryUpdatesIt() async {
        let response = Mutex<WindowSpaceSnapshot?>(WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1)]))
        let calls = Mutex(0)
        let store = TaskbarSpaceStore(read: { _ in calls.withLock { $0 += 1 }; return response.withLock { $0 } },
                                     notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: Just(DockSnapshot.empty).eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 1 }
        response.withLock { $0 = nil }
        store.refresh()
        let pending = store.pendingWorkForTesting
        for task in pending { await task.value }
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 1)
        response.withLock { $0 = WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 2)]) }
        store.refresh()
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    func testRestartRejectsThePreviousReadAndUsesTheNewInventory() async {
        let calls = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { _ = gate.wait(timeout: .now() + 2) }
            return WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: call)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([call])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let original = inventory()
        store.start(snapshots: Just(original).eraseToAnyPublisher())
        await waitUntil { calls.withLock { $0 } == 1 }
        let pending = store.pendingWorkForTesting
        store.stop()
        var replacement = original
        replacement.windows[WindowID(rawValue: "window-1")] = nil
        replacement.orderedWindowIDs = [WindowID(rawValue: "window-2")]
        store.start(snapshots: Just(replacement).eraseToAnyPublisher())
        gate.signal()
        for task in pending { await task.value }
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        XCTAssertEqual(store.snapshot.memberships.keys.map(\.itemID), ["window-2"])
        store.stop()
    }
}
