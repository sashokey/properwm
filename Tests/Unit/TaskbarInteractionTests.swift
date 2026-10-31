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
}
