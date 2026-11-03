import AppKit
import ApplicationServices
import XCTest

@MainActor
final class WindowOrderingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clock = Date(timeIntervalSince1970: 100)

    @MainActor
    override func setUp() async throws {
        suite = "properwm-order-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        clock = Date(timeIntervalSince1970: 100)
    }

    @MainActor
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(boot: Int = 1) -> StripOrderStore {
        StripOrderStore(defaults: defaults, now: { [unowned self] in self.clock },
                        bootTimeProvider: { boot })
    }

    func testManualReorderSurvivesSnapshotOrderChanges() {
        let store = makeStore()
        store.sync(current: ["a", "b", "c"])
        store.reorder(draggedID: "c", relativeTo: "a", after: false, current: ["a", "b", "c"])
        store.sync(current: ["b", "a", "c"])
        XCTAssertEqual(store.liveOrder, ["c", "a", "b"])
    }

    func testNewWindowJoinsItsLastSiblingWithoutMovingExistingWindows() {
        let store = makeStore()
        let keys = ["a": "editor", "b": "browser", "c": "editor"]
        store.sync(current: ["a", "b"], appKeyOf: keys)
        store.sync(current: ["a", "b", "c"], appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["a", "c", "b"])
    }

    func testUnrelatedNewWindowAppendsAtTheEnd() {
        XCTAssertEqual(StripOrdering.reconcile(remembered: ["b", "a"], current: ["a", "b", "c"]),
                       ["b", "a", "c"])
    }

    func testBrieflyMissingWindowKeepsItsManualPosition() {
        let store = makeStore()
        store.sync(current: ["a", "b", "c"])
        store.reorder(draggedID: "c", relativeTo: "a", after: false, current: ["a", "b", "c"])
        store.sync(current: ["a", "b"])
        XCTAssertEqual(store.reconciled(current: ["a", "b"]), ["a", "b"])
        clock.addTimeInterval(4)
        XCTAssertEqual(store.reconciled(current: ["a", "b", "c"]), ["c", "a", "b"])
        store.sync(current: ["a", "b", "c"])
        XCTAssertEqual(store.liveOrder, ["c", "a", "b"])
    }

    func testClosedWindowOrderExpiresAfterGracePeriod() {
        let store = makeStore()
        store.sync(current: ["a", "b"])
        store.sync(current: ["b"])
        clock.addTimeInterval(6)
        store.sync(current: ["b"])
        XCTAssertEqual(store.liveOrder, ["b"])
        store.sync(current: ["a", "b"])
        XCTAssertEqual(store.liveOrder, ["b", "a"])
    }

    func testSameBootRestoresWindowOrderAndNewBootStartsFresh() {
        let store = makeStore()
        let ids = ["tabgrp-1-s1", "tabgrp-2-s1"]
        store.sync(current: ids)
        store.reorder(draggedID: ids[1], relativeTo: ids[0], after: false, current: ids)
        XCTAssertEqual(makeStore().reconciled(current: ids), Array(ids.reversed()))
        XCTAssertEqual(makeStore(boot: 2).reconciled(current: ids), ids)
    }

    func testApplicationOrderSurvivesTrackerRelaunchWithDifferentSeatAllocation() throws {
        let firstTracker = AppTracker(onScreenWindowIDsProvider: { [] })
        let secondTracker = AppTracker(onScreenWindowIDsProvider: { [] })
        defer { firstTracker.stop(); secondTracker.stop() }
        for tracker in [firstTracker, secondTracker] {
            for (pid, name) in [(Int32(-51000), "Editor"), (Int32(-52000), "Browser")] {
                tracker.installFixtureForTesting(AppEntry(pid: pid, bundleIdentifier: "test.\(name)", appName: name,
                    activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false,
                    applicationOrigin: ApplicationOrigin(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"))))
            }
        }
        let editorA = orderSnapshot(pid: -51000, id: 51001)
        let editorB = orderSnapshot(pid: -51000, id: 51002)
        let browser = orderSnapshot(pid: -52000, id: 52001)
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [51001, 51002, 52001], onScreenWindowIDs: [51001, 51002, 52001],
            windowIDsByPID: [-51000: [51001, 51002], -52000: [52001]], alphaByWindowID: [:])
        func reconcile(_ tracker: AppTracker, pid: Int32, snapshots: [AXWindowSnapshot]) {
            tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cg, now: clock, eligible: snapshots,
                readOutcome: .success(count: snapshots.count))
            tracker.rebuildSnapshotForTesting(onScreenCGIDs: [51001, 51002, 52001])
        }
        reconcile(firstTracker, pid: -51000, snapshots: [editorA])
        reconcile(firstTracker, pid: -52000, snapshots: [browser])
        reconcile(firstTracker, pid: -51000, snapshots: [editorA, editorB])
        let initial = StripItem.openWindows(from: firstTracker.snapshot)
        XCTAssertEqual(initial.map(\.id), ["tabgrp--51000-s1", "tabgrp--51000-s3", "tabgrp--52000-s2"])
        let initialKeys = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.applicationKey) })
        let store = makeStore()
        store.sync(current: initial.map(\.id), appKeyOf: initialKeys)
        store.reorderGroup(try XCTUnwrap(initial.last?.applicationKey), relativeTo: try XCTUnwrap(initial.first?.applicationKey),
            after: false, current: initial.map(\.id))
        reconcile(secondTracker, pid: -51000, snapshots: [editorA, editorB])
        reconcile(secondTracker, pid: -52000, snapshots: [browser])
        let current = StripItem.openWindows(from: secondTracker.snapshot)
        XCTAssertEqual(current.map(\.id), ["tabgrp--51000-s1", "tabgrp--51000-s2", "tabgrp--52000-s3"])
        let keys = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.applicationKey) })
        let restored = makeStore()
        restored.sync(current: current.map(\.id), appKeyOf: keys)
        let order = restored.reconciled(current: current.map(\.id), appKeyOf: keys)
        XCTAssertEqual(order, ["tabgrp--52000-s3", "tabgrp--51000-s1", "tabgrp--51000-s2"])
        XCTAssertEqual(makeStore(boot: 2).reconciled(current: current.map(\.id), appKeyOf: keys), current.map(\.id))
    }

    func testRestoredApplicationRanksSurviveEmptyAndPartialStartupSnapshots() {
        let store = makeStore()
        let old = ["tabgrp-a-old", "tabgrp-b-old"]
        let oldKeys = [old[0]: "bundle:/Applications/A.app", old[1]: "bundle:/Applications/B.app"]
        store.sync(current: old, appKeyOf: oldKeys)
        store.reorderGroup("bundle:/Applications/B.app", relativeTo: "bundle:/Applications/A.app", after: false, current: old)
        let restored = makeStore()
        restored.sync(current: [])
        let current = ["tabgrp-a-new", "tabgrp-b-new"]
        let keys = [current[0]: "bundle:/Applications/A.app", current[1]: "bundle:/Applications/B.app"]
        restored.sync(current: [current[0]], appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: [current[0]], appKeyOf: keys), [current[0]])
        restored.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), [current[1], current[0]])
        restored.sync(current: [current[0]], appKeyOf: keys)
        clock.addTimeInterval(6)
        restored.sync(current: [current[0]], appKeyOf: keys)
        restored.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), current)
    }

    func testLearningApplicationKeysPersistsWithoutAnOrderChange() {
        let ids = ["tabgrp-a", "tabgrp-b"]
        let initial = makeStore()
        initial.sync(current: ids)
        initial.reorder(draggedID: ids[1], relativeTo: ids[0], after: false, current: ids)
        let keys = [ids[0]: "bundle:/Applications/A.app", ids[1]: "bundle:/Applications/B.app"]
        makeStore().sync(current: ids, appKeyOf: keys)
        let current = ["tabgrp-a-new", "tabgrp-b-new"]
        let newKeys = [current[0]: keys[ids[0]]!, current[1]: keys[ids[1]]!]
        let restored = makeStore()
        restored.sync(current: current, appKeyOf: newKeys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: newKeys), [current[1], current[0]])
    }

    func testExpiredApplicationRankDoesNotReturnWithANewSeatWithoutAnIntermediateSync() {
        let store = makeStore()
        let keys = ["a-old": "editor", "b": "browser", "a-new": "editor"]
        store.sync(current: ["a-old", "b"], appKeyOf: keys)
        store.sync(current: ["b"], appKeyOf: keys)
        clock.addTimeInterval(6)
        XCTAssertEqual(store.reconciled(current: ["b", "a-new"], appKeyOf: keys), ["b", "a-new"])
        store.sync(current: ["b", "a-new"], appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["b", "a-new"])
        XCTAssertEqual(makeStore().reconciled(current: ["b", "a-new"], appKeyOf: keys), ["b", "a-new"])
    }

    private func orderSnapshot(pid: Int32, id: UInt32) -> AXWindowSnapshot {
        AXWindowSnapshot(pid: pid, cgWindowID: id, titleRead: .value("Window \(id)"),
            bounds: CGRect(x: CGFloat(id % 100) * 50, y: 100, width: 600, height: 400),
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
            isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(pid))
    }

    func testReorderingOneDisplayKeepsOtherDisplayWindowsInGlobalOrder() {
        let store = makeStore()
        let ids = ["a-left", "b-right", "c-left", "d-right"]
        store.sync(current: ids)
        store.reorder(draggedID: "c-left", relativeTo: "a-left", after: false, current: ids)
        XCTAssertEqual(store.liveOrder, ["c-left", "a-left", "b-right", "d-right"])
        XCTAssertEqual(store.liveOrder.filter { $0.hasSuffix("right") }, ["b-right", "d-right"])
    }

    func testInvalidDragTargetsDoNotChangeOrder() {
        let order = ["a", "b"]
        for pair in [("a", "a"), ("missing", "a"), ("a", "missing")] {
            XCTAssertEqual(StripOrdering.reordering(order, move: pair.0, relativeTo: pair.1, after: true), order)
        }
    }
}
