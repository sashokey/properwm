import Combine
import XCTest
@testable import ProperWM

@MainActor
final class DisplayTopologyStoreTests: XCTestCase {
    func testApplyPublishesUpdatedAttributionTable() {
        let initial = snapshot(uuid: "A", physicalCount: 1)
        let updated = snapshot(uuid: "B", physicalCount: 2)
        let store = DisplayTopologyStore(initialSnapshot: initial)
        var publications: [WindowDisplayAttribution.Table] = []
        let subscription = store.$table.dropFirst().sink { publications.append($0) }

        store.apply(updated)

        XCTAssertEqual(store.table, updated.attributionTable)
        XCTAssertEqual(publications, [updated.attributionTable])
        withExtendedLifetime(subscription) {}
    }

    func testApplyingSameTableDoesNotPublishAgain() {
        let initial = snapshot(uuid: "A", physicalCount: 1)
        let sameTable = ScreenTopologySnapshot(
            physicalDisplayCount: 2,
            identifiedDisplayUUIDs: initial.identifiedDisplayUUIDs,
            attributionTable: initial.attributionTable
        )
        let store = DisplayTopologyStore(initialSnapshot: initial)
        var publications = 0
        let subscription = store.$table.dropFirst().sink { _ in publications += 1 }

        store.apply(sameTable)

        XCTAssertEqual(store.table, initial.attributionTable)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    private func snapshot(uuid: String, physicalCount: Int) -> ScreenTopologySnapshot {
        let display = WindowDisplayAttribution.Display(
            uuid: uuid,
            cgFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let table = WindowDisplayAttribution.Table(displays: [display], primaryUUID: uuid)
        return ScreenTopologySnapshot(
            physicalDisplayCount: physicalCount,
            identifiedDisplayUUIDs: [uuid],
            attributionTable: table
        )
    }
}
