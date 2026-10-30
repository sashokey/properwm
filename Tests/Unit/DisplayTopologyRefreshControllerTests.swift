import XCTest
@testable import macos_dock_cc_v2

@MainActor
final class DisplayTopologyRefreshControllerTests: XCTestCase {
    func testCompleteSnapshotAppliesSynchronouslyWithoutRetries() {
        for count in [0, 1, 2, 3] {
            let snapshot = Self.snapshot(physical: count, uuids: (0..<count).map(String.init))
            let harness = Harness(snapshots: [snapshot])
            XCTAssertEqual(harness.controller.prepareForTopologyChange(), snapshot)
            XCTAssertEqual(harness.appliedSnapshots, [snapshot])
            XCTAssertTrue(harness.scheduler.entries.isEmpty)
            XCTAssertTrue(harness.retrySnapshots.isEmpty)
        }
    }

    func testIncompleteSnapshotSchedulesBoundedRetries() {
        let harness = Harness(snapshots: [Self.snapshot(physical: 2, uuids: ["A"])])
        _ = harness.controller.prepareForTopologyChange()
        XCTAssertEqual(harness.scheduler.entries.map(\.delay), [0.5, 2.0])
    }

    func testSuccessfulRetryPublishesSameSnapshotAndCancelsRemainingWork() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let complete = Self.snapshot(physical: 2, uuids: ["A", "B"])
        let harness = Harness(snapshots: [incomplete, complete])
        _ = harness.controller.prepareForTopologyChange()
        harness.scheduler.fire(0)
        XCTAssertEqual(harness.appliedSnapshots, [incomplete, complete])
        XCTAssertEqual(harness.retrySnapshots, [complete])
        XCTAssertTrue(harness.scheduler.entries[1].item.isCancelled)
    }

    func testSecondRetryCanCompleteTheDisplayList() {
        let incomplete = Self.snapshot(physical: 3, uuids: ["A"])
        let partial = Self.snapshot(physical: 3, uuids: ["A", "B"])
        let complete = Self.snapshot(physical: 3, uuids: ["A", "B", "C"])
        let harness = Harness(snapshots: [incomplete, partial, complete])
        _ = harness.controller.prepareForTopologyChange()
        harness.scheduler.fire(0)
        harness.scheduler.fire(1)
        XCTAssertEqual(harness.retrySnapshots, [partial, complete])
        XCTAssertEqual(harness.appliedSnapshots.last, complete)
    }

    func testRetryExhaustionDoesNotScheduleAnUnboundedLoop() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let harness = Harness(snapshots: [incomplete])
        _ = harness.controller.prepareForTopologyChange()
        harness.scheduler.fire(0)
        harness.scheduler.fire(1)
        XCTAssertEqual(harness.scheduler.entries.count, 2)
        XCTAssertEqual(harness.appliedSnapshots.count, 3)
    }

    func testOldGenerationCannotPublishAfterAnotherTopologyChange() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let complete = Self.snapshot(physical: 1, uuids: ["B"])
        let harness = Harness(snapshots: [incomplete, complete])
        _ = harness.controller.prepareForTopologyChange()
        let oldAction = harness.scheduler.entries[0].action
        _ = harness.controller.prepareForTopologyChange()
        oldAction()
        XCTAssertEqual(harness.appliedSnapshots, [incomplete, complete])
        XCTAssertTrue(harness.retrySnapshots.isEmpty)
    }

    func testCancellationRejectsAlreadyQueuedCallbacks() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let harness = Harness(snapshots: [incomplete])
        _ = harness.controller.prepareForTopologyChange()
        let action = harness.scheduler.entries[0].action
        harness.controller.cancel()
        action()
        XCTAssertEqual(harness.appliedSnapshots, [incomplete])
        XCTAssertTrue(harness.scheduler.entries.allSatisfy { $0.item.isCancelled })
    }

    func testCompletionRejectsAlreadyQueuedSecondCallback() {
        let incomplete = Self.snapshot(physical: 2, uuids: ["A"])
        let complete = Self.snapshot(physical: 2, uuids: ["A", "B"])
        let harness = Harness(snapshots: [incomplete, complete])
        _ = harness.controller.prepareForTopologyChange()
        let lateAction = harness.scheduler.entries[1].action
        harness.scheduler.fire(0)
        lateAction()
        XCTAssertEqual(harness.appliedSnapshots, [incomplete, complete])
        XCTAssertEqual(harness.retrySnapshots, [complete])
    }

    private static func snapshot(physical: Int, uuids: [String]) -> ScreenTopologySnapshot {
        let displays = uuids.enumerated().map { index, uuid in
            WindowDisplayAttribution.Display(
                uuid: uuid,
                cgFrame: CGRect(x: CGFloat(index * 100), y: 0, width: 100, height: 100)
            )
        }
        return ScreenTopologySnapshot(
            physicalDisplayCount: physical,
            identifiedDisplayUUIDs: uuids,
            attributionTable: .init(displays: displays, primaryUUID: uuids.first)
        )
    }
}

@MainActor
private final class Harness {
    var appliedSnapshots: [ScreenTopologySnapshot] = []
    var retrySnapshots: [ScreenTopologySnapshot] = []
    let scheduler = ManualTopologyScheduler()
    private let snapshots: [ScreenTopologySnapshot]
    private var snapshotIndex = 0

    init(snapshots: [ScreenTopologySnapshot]) {
        self.snapshots = snapshots
    }

    lazy var controller = DisplayTopologyRefreshController(
        snapshotProvider: { [unowned self] in
            let index = min(snapshotIndex, snapshots.count - 1)
            snapshotIndex += 1
            return snapshots[index]
        },
        applySnapshot: { [unowned self] in appliedSnapshots.append($0) },
        onRetrySnapshot: { [unowned self] in retrySnapshots.append($0) },
        scheduleAfter: { [unowned self] delay, action in
            scheduler.schedule(after: delay, action: action)
        }
    )
}

@MainActor
private final class ManualTopologyScheduler {
    struct Entry {
        let delay: TimeInterval
        let action: () -> Void
        let item: DispatchWorkItem
    }

    private(set) var entries: [Entry] = []

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: action)
        entries.append(Entry(delay: delay, action: action, item: item))
        return item
    }

    func fire(_ index: Int) {
        let entry = entries[index]
        guard !entry.item.isCancelled else { return }
        entry.action()
    }
}
