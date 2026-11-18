import XCTest

@MainActor
final class TaskbarInteractionTests: XCTestCase {
    @MainActor
    private final class Clock {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var completed = 0
        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { waiters.append($0) }
            completed += 1
        }
        func resume() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition())
    }

    func testLeavingBeforeDelayCannotActivateTheWindow() async {
        let clock = Clock()
        let action = TaskbarDelayedAction(delay: { await clock.sleep($0) })
        var activated = false
        action.schedule(target: "first", after: .milliseconds(600)) { activated = true }
        await waitFor { clock.waiters.count == 1 }
        action.cancel()
        clock.resume()
        await waitFor { clock.completed == 1 }
        XCTAssertFalse(activated)
    }

    func testMovingToAnotherWindowInvalidatesTheEarlierActivation() async {
        let clock = Clock()
        let action = TaskbarDelayedAction(delay: { await clock.sleep($0) })
        var activated: [String] = []
        action.schedule(target: "first", after: .milliseconds(600)) { activated.append("first") }
        await waitFor { clock.waiters.count == 1 }
        action.schedule(target: "second", after: .milliseconds(600)) { activated.append("second") }
        await waitFor { clock.waiters.count == 2 }
        clock.resume()
        await waitFor { activated == ["second"] && clock.completed == 2 }
        XCTAssertEqual(activated, ["second"])
    }

    func testRepeatedDragUpdatesDoNotPostponeActivationOrRepeatIt() async {
        let clock = Clock()
        let action = TaskbarDelayedAction(delay: { await clock.sleep($0) })
        var count = 0
        for _ in 0..<20 { action.schedule(target: "same", after: .milliseconds(600)) { count += 1 } }
        await waitFor { clock.waiters.count == 1 }
        XCTAssertEqual(clock.waiters.count, 1)
        clock.resume()
        await waitFor { count == 1 }
        action.schedule(target: "same", after: .milliseconds(600)) { count += 1 }
        await Task.yield()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(clock.waiters.isEmpty)
    }

    func testReenteringTheSameWindowDoesNotReviveACancelledAction() async {
        let clock = Clock()
        let action = TaskbarDelayedAction(delay: { await clock.sleep($0) })
        var calls: [String] = []
        action.schedule(target: "same", after: .milliseconds(600)) { calls.append("stale") }
        await waitFor { clock.waiters.count == 1 }
        action.cancel()
        action.schedule(target: "same", after: .milliseconds(600)) { calls.append("current") }
        await waitFor { clock.waiters.count == 2 }
        clock.resume()
        await waitFor { calls == ["current"] && clock.completed == 2 }
        XCTAssertEqual(calls, ["current"])
    }

    func testClosingEitherDragParticipantCancelsTheMove() {
        for remaining in [["dragged", "other"], ["target", "other"]] {
            var drag = TaskbarGroupDrag()
            drag.update(groupID: "dragged", target: "target", after: true, liveGroups: ["dragged", "target", "other"])
            drag.reconcile(liveGroups: remaining)
            XCTAssertNil(drag.target)
            XCTAssertEqual(drag.order(remaining), remaining)
        }
    }

    func testApplicationsOpenedDuringDraggingRemainVisible() {
        var drag = TaskbarGroupDrag()
        drag.update(groupID: "a", target: "b", after: true, liveGroups: ["a", "b"])
        XCTAssertEqual(drag.order(["a", "b", "new"]), ["b", "a", "new"])
    }

    func testDragCancellationRestoresOriginalOrderWithoutPersisting() {
        var drag = TaskbarGroupDrag()
        let order = ["a", "b", "c"]
        drag.update(groupID: "a", target: "c", after: true, liveGroups: order)
        XCTAssertEqual(drag.order(order), ["b", "c", "a"])
        drag.cancel()
        XCTAssertEqual(drag.order(order), order)
        XCTAssertNil(drag.target)
    }

    private func dragLayout(_ order: [String]) -> TaskbarLayoutResult {
        TaskbarLayout.resolve(groups: order.map { id in
            let widths: [CGFloat] = id == "wide" ? [164, 164] : id == "narrow" ? [80] : [100]
            return TaskbarLayoutGroup(id: id, desiredWidth: 80, windows: widths.enumerated().map {
                TaskbarLayoutWindow(id: "\(id)-\($0.offset)", desiredWidth: $0.element)
            })
        }, width: 1000)
    }

    private func groupFrame(_ id: String, in layout: TaskbarLayoutResult) -> CGRect {
        layout.buttons.filter { $0.groupID == id }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    func testLeadingGroupEdgeCrossingANeighborCenterTriggersALeftMove() {
        let order = ["narrow", "wide"]
        let layout = dragLayout(order)
        let wide = groupFrame("wide", in: layout)
        let neighbor = groupFrame("narrow", in: layout)
        var drag = TaskbarGroupDrag()
        var moved = wide
        moved.origin.x = neighbor.midX + 1
        drag.update(groupID: "wide", draggedFrame: moved, buttons: layout.buttons, liveGroups: order)
        XCTAssertNil(drag.target)
        moved.origin.x = neighbor.midX - 1
        drag.update(groupID: "wide", draggedFrame: moved, buttons: layout.buttons, liveGroups: order)
        XCTAssertEqual(drag.order(order), ["wide", "narrow"])
        XCTAssertGreaterThan(moved.minX + wide.width - 4, neighbor.maxX)
    }

    func testTrailingGroupEdgeCrossingANeighborCenterTriggersARightMove() {
        let order = ["wide", "narrow"]
        let layout = dragLayout(order)
        let wide = groupFrame("wide", in: layout)
        let neighbor = groupFrame("narrow", in: layout)
        var drag = TaskbarGroupDrag()
        var moved = wide
        moved.origin.x = neighbor.midX - wide.width - 1
        drag.update(groupID: "wide", draggedFrame: moved, buttons: layout.buttons, liveGroups: order)
        XCTAssertNil(drag.target)
        moved.origin.x += 2
        drag.update(groupID: "wide", draggedFrame: moved, buttons: layout.buttons, liveGroups: order)
        XCTAssertEqual(drag.order(order), ["narrow", "wide"])
        XCTAssertLessThan(moved.minX + 4, neighbor.minX)
    }

    func testNeighborThresholdUsesItsEntireGroupInsteadOfItsFirstButton() {
        let order = ["narrow", "wide"]
        let layout = dragLayout(order)
        let narrow = groupFrame("narrow", in: layout)
        let neighbor = groupFrame("wide", in: layout)
        var drag = TaskbarGroupDrag()
        var moved = narrow
        moved.origin.x = neighbor.midX - narrow.width - 1
        drag.update(groupID: "narrow", draggedFrame: moved, buttons: layout.buttons, liveGroups: order)
        XCTAssertNil(drag.target)
        moved.origin.x += 2
        drag.update(groupID: "narrow", draggedFrame: moved, buttons: layout.buttons, liveGroups: order)
        XCTAssertEqual(drag.order(order), ["wide", "narrow"])
    }

    func testReturningToTheOriginalSlotClearsThePendingMove() {
        let order = ["narrow", "wide", "other"]
        let initial = dragLayout(order)
        let original = groupFrame("wide", in: initial)
        var drag = TaskbarGroupDrag()
        let left = CGRect(x: 10, y: 2, width: original.width, height: 28)
        drag.update(groupID: "wide", draggedFrame: left, buttons: initial.buttons, liveGroups: order)
        XCTAssertEqual(drag.order(order), ["wide", "narrow", "other"])
        let preview = dragLayout(drag.order(order))
        drag.update(groupID: "wide", draggedFrame: original, buttons: preview.buttons, liveGroups: order)
        XCTAssertEqual(drag.order(order), order)
        XCTAssertNil(drag.target)
    }

    func testOneMoveCanCrossMultipleGroupsAndRemainStableWithoutPointerMotion() {
        let order = ["narrow", "other", "wide"]
        let layout = dragLayout(order)
        let wide = groupFrame("wide", in: layout)
        let moved = CGRect(x: 10, y: 2, width: wide.width, height: 28)
        var drag = TaskbarGroupDrag()
        for _ in 0..<10 {
            let current = dragLayout(drag.order(order))
            drag.update(groupID: "wide", draggedFrame: moved, buttons: current.buttons, liveGroups: order)
            XCTAssertEqual(drag.order(order), ["wide", "narrow", "other"])
        }
        let current = dragLayout(drag.order(order))
        drag.update(groupID: "wide", draggedFrame: wide, buttons: current.buttons, liveGroups: order)
        XCTAssertEqual(drag.order(order), order)
        XCTAssertNil(drag.target)
    }

    func testDragGeometryKeepsTheGroupOnTheTaskbarWhileThePointerLeavesIt() {
        let geometry = TaskbarDragGeometry.make(pointer: CGPoint(x: 60, y: 16),
                                                groupFrame: CGRect(x: 10, y: 2, width: 280, height: 28))
        let occupied = CGRect(x: 10, y: 2, width: 600, height: 28)
        for point in [CGPoint(x: -1000, y: -1000), CGPoint(x: 10000, y: 10000), CGPoint(x: 300, y: -400)] {
            let frame = geometry.frame(pointer: point, groupWidth: 280, occupiedBounds: occupied)
            XCTAssertEqual(frame.minY, 2)
            XCTAssertEqual(frame.height, 28)
            XCTAssertGreaterThanOrEqual(frame.minX, occupied.minX)
            XCTAssertLessThanOrEqual(frame.maxX, occupied.maxX)
        }
        XCTAssertEqual(geometry.frame(pointer: CGPoint(x: 300, y: -400), groupWidth: 280, occupiedBounds: occupied).minX, 250)
    }

    func testTheOnlyGroupCannotBeDraggedIntoEmptyTaskbarSpace() {
        let group = CGRect(x: 10, y: 2, width: 140, height: 28)
        let geometry = TaskbarDragGeometry.make(pointer: CGPoint(x: 60, y: 16), groupFrame: group)
        XCTAssertEqual(geometry.frame(pointer: CGPoint(x: 700, y: -300), groupWidth: 140, occupiedBounds: group), group)
    }
}
