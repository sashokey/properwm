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
    func testIconRecoveryRefreshesExistingButtonsWithoutAnInventoryChange() async throws {
        let fixture = SpaceInventory(inventory())
        let runtime = AppRuntime(tracker: fixture, isAccessibilityTrusted: { true })
        let center = NotificationCenter()
        var resolved = false
        var rendered = false
        let icons = AppIconResolver(notifications: center, applicationURL: { _ in
            resolved ? URL(fileURLWithPath: "/fixture/Icon.app") : nil
        }, imageForFile: { _ in rendered = true; return NSImage(size: .init(width: 32, height: 32)) },
            fallbackImage: { NSImage(size: .init(width: 32, height: 32)) })
        let store = TaskbarSpaceStore(read: { requests in
            .init(layouts: ["left": .init(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1)],
                  memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "ProperWM.IconRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["left"], attributionTable: .empty))
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: StripOrderStore(defaults: defaults),
            topology: topology, spaces: store, displayUUID: nil, backgroundMenu: { _, _ in },
            popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in }, icons: icons)
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenter) {} }
        await waitUntil { view.taskbarContent.buttonViews.count == 2 && store.snapshot.memberships.count == 2 }
        let button = try XCTUnwrap(view.taskbarContent.buttonViews.values.first)
        let originalImage = button.image
        let originalSnapshot = runtime.snapshot
        resolved = true
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await waitUntil { rendered && button.image !== originalImage }
        XCTAssertEqual(runtime.snapshot, originalSnapshot)
        XCTAssertNil(view.window)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func reorderSecondBeforeFirst(_ ordering: StripOrderStore) {
        let items = StripItem.openWindows(from: inventory())
        ordering.reorderGroup(items[1].applicationKey, relativeTo: items[0].applicationKey,
                              after: false, current: items.map(\.id))
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
        reorderSecondBeforeFirst(ordering)
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

    private func flushSnapshotDelivery() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private var twoDisplayLayouts: [String: SpaceLayoutSnapshot] {
        ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1),
         "right": SpaceLayoutSnapshot(orderedSpaceIDs: [10, 11], fullscreenSpaceIDs: [], currentSpaceID: 10)]
    }

    func testDisplayTransferUpdatesBothPresentersWithoutPollingOrSpaceNotifications() async {
        let original = inventory()
        let fixture = SpaceInventory(original)
        let runtime = AppRuntime(tracker: fixture, isAccessibilityTrusted: { true })
        let currentMembership = Mutex<Set<Int>>([1])
        let calls = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            calls.withLock { $0 += 1 }
            let movedSpace = currentMembership.withLock { $0 }
            return WindowSpaceSnapshot(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues:
                requests.map { ($0.identity, $0.identity.windowID == 1 ? movedSpace : Set([1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "ProperWM.DisplayTransferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let topology = DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"],
            attributionTable: WindowDisplayAttribution.Table(displays: [
                .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                .init(uuid: "right", cgFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ], primaryUUID: "left")
        ))
        let left = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let right = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let presenters = [("left", left), ("right", right)].map { display, view in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
                topology: topology, spaces: store, displayUUID: display,
                backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        }
        func ids(_ view: TaskbarView) -> [String] { view.taskbarContent.groups.flatMap(\.windows).map(\.id) }
        runtime.start()
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenters) {} }
        await waitUntil { runtime.snapshot.windows.count == 2 }
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        await waitUntil { store.snapshot.memberships.count == 2 && ids(left) == ["window-1", "window-2"] }
        XCTAssertTrue(ids(right).isEmpty)
        reorderSecondBeforeFirst(ordering)
        await waitUntil { ids(left) == ["window-2", "window-1"] }
        var moved = original
        moved.windows[WindowID(rawValue: "window-1")]?.displayUUID = "right"
        currentMembership.withLock { $0 = [10] }
        fixture.values.send(moved)
        await waitUntil { ids(left) == ["window-2"] && ids(right) == ["window-1"] }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(ordering.liveOrder, ["window-2", "window-1"])
        currentMembership.withLock { $0 = [1] }
        fixture.values.send(original)
        await waitUntil { ids(left) == ["window-2", "window-1"] && ids(right).isEmpty }
        XCTAssertEqual(calls.withLock { $0 }, 3)
        XCTAssertEqual(runtime.snapshot.windows.count, 2)
        XCTAssertNil(left.window)
        XCTAssertNil(right.window)
    }

    func testDisplayChangesDuringAReadCoalesceAndRejectOldMembership() async {
        let original = inventory()
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let calls = Mutex(0)
        let membership = Mutex<Set<Int>>([1])
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            let spaces = membership.withLock { $0 }
            if call == 1 { _ = firstGate.wait(timeout: .now() + 3) }
            if call == 2 { _ = secondGate.wait(timeout: .now() + 3) }
            return WindowSpaceSnapshot(layouts: layouts,
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, spaces) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { firstGate.signal(); secondGate.signal(); store.stop() }
        await waitUntil { calls.withLock { $0 } == 1 }
        for display in ["right", "left", "right"] {
            var moved = original
            moved.windows[WindowID(rawValue: "window-1")]?.displayUUID = display
            source.send(moved)
        }
        membership.withLock { $0 = [10] }
        await flushSnapshotDelivery()
        firstGate.signal()
        await waitUntil { calls.withLock { $0 } == 2 }
        XCTAssertTrue(store.snapshot.memberships.isEmpty)
        secondGate.signal()
        await waitUntil { store.snapshot.memberships.values.allSatisfy { $0 == [10] } && store.snapshot.memberships.count == 2 }
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testSameDisplayGeometryTitleAndFocusChangesDoNotRefreshSpaces() async {
        let source = CurrentValueSubject<DockSnapshot, Never>(inventory())
        let calls = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            calls.withLock { $0 += 1 }
            return WindowSpaceSnapshot(layouts: layouts,
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships.count == 2 }
        for index in 0..<20 {
            var changed = source.value
            let key = WindowID(rawValue: "window-1")
            changed.windows[key]?.bounds = CGRect(x: 10 + index, y: 100, width: 900, height: 600)
            changed.windows[key]?.title = "Updated \(index)"
            changed.windows[key]?.status = index.isMultiple(of: 2) ? .active : .inactive
            source.send(changed)
        }
        await flushSnapshotDelivery()
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testResolvingAnUnknownDisplayRefreshesMembership() async {
        var original = inventory()
        let key = WindowID(rawValue: "window-1")
        original.windows[key]?.displayUUID = nil
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let calls = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            return WindowSpaceSnapshot(layouts: layouts,
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([call == 1 ? 1 : 10])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships.count == 2 }
        var resolved = original
        resolved.windows[key]?.displayUUID = "right"
        source.send(resolved)
        await waitUntil { calls.withLock { $0 } == 2 && store.snapshot.memberships.values.allSatisfy { $0 == [10] } }
    }

}
