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
