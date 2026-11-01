import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

@MainActor
private final class CommandInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }
    init() {
        let windows = (1...2).map {
            WindowRecord(id: WindowID(rawValue: "review-\($0)"), appID: AppID(rawValue: "review"), pid: 42,
                         bundleIdentifier: "test.review", title: "Window", bounds: nil, status: .inactive, cgWindowID: UInt32($0))
        }
        values = CurrentValueSubject(DockSnapshot(windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }),
                                                  orderedWindowIDs: windows.map(\.id)))
    }
    func start() {}
    func stop() {}
}

private final class ControlledWindowExecutor: WindowActionExecuting {
    let calls = Mutex(0)
    let cancellations = Mutex<[OperationCancellation]>([])
    let effects = Mutex<[String]>([])
    let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot, forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation, onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        let index = calls.withLock { value in defer { value += 1 }; return value }
        cancellations.withLock { $0.append(cancellation) }
        guard gates.indices.contains(index), gates[index].wait(timeout: .now() + 3) == .success,
              !cancellation.isCancelled else { return false }
        effects.withLock { $0.append("\(request.windowID!.rawValue):\(request.kind.rawValue)") }
        return true
    }
}

@MainActor
final class WindowCommandLifecycleTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func start(_ executor: ControlledWindowExecutor) async -> AppRuntime {
        let runtime = AppRuntime(tracker: CommandInventory(), actionExecutor: executor, isAccessibilityTrusted: { true })
        runtime.start()
        await waitUntil { runtime.snapshot.windows.count == 2 }
        return runtime
    }

    func testBulkCommandsKeepOneWorkerAndExecuteEveryLiveWindow() async {
        let queue = WindowActionQueue()
        let completed = Mutex<[Int]>([])
        for index in 0..<100 {
            XCTAssertTrue(queue.submit(key: "window-\(index)", maximumPendingKeys: 100) { _, _ in
                completed.withLock { $0.append(index) }
            })
        }
        XCTAssertEqual(queue.pendingForTesting.count, 1)
        for task in queue.pendingForTesting { await task.value }
        XCTAssertEqual(completed.withLock { $0 }, Array(0..<100))
        queue.stop()
    }

    func testRetiredWindowsAreRemovedBeforeQueuedMutations() async {
        let queue = WindowActionQueue()
        let completed = Mutex<[String]>([])
        queue.submit(key: "gone") { _, _ in completed.withLock { $0.append("gone") } }
        queue.submit(key: "live") { _, _ in completed.withLock { $0.append("live") } }
        queue.retain(windowIDs: ["live"])
        for task in queue.pendingForTesting { await task.value }
        XCTAssertEqual(completed.withLock { $0 }, ["live"])
        queue.stop()
    }

    func testRepeatedQueuedCommandsHaveBoundedRetainedWork() async {
        let queue = WindowActionQueue()
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        queue.submit(key: "blocked") { _, _ in
            _ = await AsyncWorkScope.performBlocking {
                entered.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 3)
            }
        }
        await waitUntil { entered.withLock { $0 } }
        for _ in 0..<500 { queue.submit(key: "latest") { _, _ in } }
        XCTAssertLessThanOrEqual(queue.pendingForTesting.count, 33)
        queue.stop()
        gate.signal()
        for task in queue.pendingForTesting { await task.value }
    }

    func testStopCancelsMutationAfterAnInFlightReadReturns() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor)
        runtime.minimize(windowID: "review-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let pending = runtime.pendingActionsForTesting
        runtime.stop()
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertTrue(executor.effects.withLock { $0.isEmpty })
    }

    func testNewActivateCancelsOlderMinimizeAndWaitsForItsInFlightCall() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor)
        defer { runtime.stop() }
        runtime.minimize(windowID: "review-1")
        await waitUntil { executor.cancellations.withLock { $0.count } == 1 }
        runtime.activate(windowID: "review-1")
        XCTAssertTrue(executor.cancellations.withLock { $0[0].isCancelled })
        await Task.yield()
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
        let pending = runtime.pendingActionsForTesting
        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        executor.gates[1].signal()
        for task in pending { await task.value }
        XCTAssertEqual(executor.effects.withLock { $0 }, ["review-1:activateWindow"])
    }

    func testDifferentWindowsExecuteInSubmissionOrder() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor)
        defer { runtime.stop() }
        runtime.close(windowID: "review-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        runtime.close(windowID: "review-2")
        let pending = runtime.pendingActionsForTesting
        executor.gates[1].signal()
        await Task.yield()
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertEqual(executor.effects.withLock { $0 }, ["review-1:closeWindow", "review-2:closeWindow"])
    }

    func testRestartDrainsThePreviousOperationBeforeStartingANewOne() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor)
        runtime.minimize(windowID: "review-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        runtime.stop()
        runtime.start()
        defer { runtime.stop() }
        await waitUntil { runtime.snapshot.windows.count == 2 }
        runtime.activate(windowID: "review-2")
        let pending = runtime.pendingActionsForTesting
        executor.gates[1].signal()
        await Task.yield()
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertEqual(executor.effects.withLock { $0 }, ["review-2:activateWindow"])
    }

    func testCancelledQueuedCommandsStillDrainTheOriginalInFlightOperation() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor)
        runtime.minimize(windowID: "review-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        for _ in 0..<20 { runtime.activate(windowID: "review-2") }
        runtime.stop()
        runtime.start()
        defer { runtime.stop() }
        await waitUntil { runtime.snapshot.windows.count == 2 }
        runtime.activate(windowID: "review-2")
        let pending = runtime.pendingActionsForTesting
        executor.gates[1].signal()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertEqual(executor.effects.withLock { $0 }, ["review-2:activateWindow"])
    }

    func testCancellationAfterFocusConfirmationPreventsFallbackWrites() {
        let cancellation = OperationCancellation()
        var calls: [String] = []
        XCTAssertFalse(WindowActivationAttempt.run(requestPrivateFocus: { calls.append("private"); return false },
            raise: { calls.append("raise") }, activateApplication: { calls.append("fallback") },
            confirm: { _ in cancellation.cancel(); return false }, timeout: 0.2,
            isCancelled: { cancellation.isCancelled }))
        XCTAssertEqual(calls, ["private", "raise"])
    }
}
