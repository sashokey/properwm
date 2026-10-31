import AppKit
import Combine
import Synchronization
import XCTest

@MainActor
private final class RuntimeInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var starts = 0
    var stops = 0
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }

    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

private final class RuntimeExecutor: WindowActionExecuting {
    let calls = Mutex(0)
    let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
    let results: [Bool]
    let predictedWindow: WindowID?

    init(results: [Bool], predictedWindow: WindowID? = nil) {
        self.results = results
        self.predictedWindow = predictedWindow
    }

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                 forcedMinimizedPrior: Bool,
                 onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        let index = calls.withLock { value in
            defer { value += 1 }
            return value
        }
        guard gates.indices.contains(index), results.indices.contains(index) else { return false }
        guard gates[index].wait(timeout: .now() + 3) == .success else { return false }
        if let predictedWindow { onHandoffActivePrediction?(predictedWindow) }
        return results[index]
    }
}

@MainActor
final class AppRuntimeTests: XCTestCase {
    private func snapshot() -> DockSnapshot {
        let records = (1...2).map { index in
            WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "test"), pid: 42,
                         bundleIdentifier: "test.runtime", title: "Window \(index)", bounds: nil,
                         status: .inactive, cgWindowID: UInt32(index))
        }
        return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                            orderedWindowIDs: records.map(\.id))
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func start(_ executor: RuntimeExecutor) async -> (AppRuntime, RuntimeInventory) {
        let inventory = RuntimeInventory(snapshot())
        let runtime = AppRuntime(tracker: inventory, actionExecutor: executor, isAccessibilityTrusted: { true })
        runtime.start()
        await waitUntil { runtime.snapshot.windows.count == 2 }
        return (runtime, inventory)
    }

    func testFailedActionClearsItsOptimisticStateImmediately() async {
        let executor = RuntimeExecutor(results: [false])
        let (runtime, _) = await start(executor)
        defer { runtime.stop() }
        runtime.activate(windowID: "window-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-1"]?.status, .active)
        let pending = runtime.pendingActionsForTesting
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertNil(runtime.optimisticStatesByWindowID["window-1"])
        XCTAssertEqual(runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase, .failure)
    }

    func testOlderFailureCannotClearNewerSuccessfulIntent() async {
        let executor = RuntimeExecutor(results: [false, true])
        let (runtime, _) = await start(executor)
        defer { runtime.stop() }
        runtime.activate(windowID: "window-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let older = runtime.pendingActionsForTesting
        runtime.activate(windowID: "window-1")
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        executor.gates[1].signal()
        await waitUntil { runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase == .success }
        executor.gates[0].signal()
        for task in older { await task.value }
        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-1"]?.status, .active)
        XCTAssertEqual(runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase, .success)
    }

    func testStopAndRestartRejectLateExecutionAndHandoffPrediction() async {
        let executor = RuntimeExecutor(results: [false], predictedWindow: WindowID(rawValue: "window-2"))
        let (runtime, inventory) = await start(executor)
        runtime.minimize(windowID: "window-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let pending = runtime.pendingActionsForTesting
        runtime.stop()
        XCTAssertTrue(runtime.snapshot.windows.isEmpty)
        XCTAssertTrue(runtime.optimisticStatesByWindowID.isEmpty)
        XCTAssertTrue(runtime.debugState.feedbackEntriesByWindowID.isEmpty)
        runtime.start()
        defer { runtime.stop() }
        await waitUntil { runtime.snapshot.windows.count == 2 }
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertTrue(runtime.optimisticStatesByWindowID.isEmpty)
        XCTAssertTrue(runtime.debugState.feedbackEntriesByWindowID.isEmpty)
        XCTAssertEqual(inventory.starts, 2)
        XCTAssertEqual(inventory.stops, 1)
    }

    func testStoppedRuntimeDoesNotDispatchActionsOrAcceptSnapshots() async {
        let executor = RuntimeExecutor(results: [])
        let (runtime, inventory) = await start(executor)
        runtime.stop()
        runtime.activate(windowID: "window-1")
        inventory.values.send(snapshot())
        XCTAssertTrue(runtime.pendingActionsForTesting.isEmpty)
        XCTAssertEqual(executor.calls.withLock { $0 }, 0)
        XCTAssertTrue(runtime.optimisticStatesByWindowID.isEmpty)
        XCTAssertTrue(runtime.snapshot.windows.isEmpty)
    }

    func testReleasingRuntimeStopsItsInventorySubscription() {
        let inventory = RuntimeInventory(snapshot())
        var runtime: AppRuntime? = AppRuntime(tracker: inventory, actionExecutor: RuntimeExecutor(results: []),
                                             isAccessibilityTrusted: { true })
        weak var reference = runtime
        runtime?.start()
        runtime = nil
        XCTAssertNil(reference)
        XCTAssertEqual(inventory.stops, 1)
    }

    func testCancelledBackgroundOperationNeverExecutesItsSideEffect() async {
        let queue = DispatchQueue(label: "test.cancelled-actions")
        let calls = Mutex(0)
        queue.suspend()
        let task = Task {
            await AsyncWorkScope.performBlocking(on: queue) {
                calls.withLock { $0 += 1 }
                return true
            }
        }
        task.cancel()
        queue.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testBackgroundOperationRunsOffMainAndReturnsItsResult() async {
        let result = await AsyncWorkScope.performBlocking { !Thread.isMainThread }
        XCTAssertEqual(result, true)
    }
}
