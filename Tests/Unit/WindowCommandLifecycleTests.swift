import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

@MainActor
private final class CommandInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }
    convenience init(activeWindowID: String? = nil) {
        let windows = (1...2).map {
            WindowRecord(id: WindowID(rawValue: "review-\($0)"), appID: AppID(rawValue: "review"), pid: 42,
                         bundleIdentifier: "test.review", title: "Window", bounds: nil,
                         status: activeWindowID == "review-\($0)" ? .active : .inactive, cgWindowID: UInt32($0))
        }
        self.init(windows: windows)
    }
    init(windows: [WindowRecord]) {
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
    let closeGroups = Mutex<[String?]>([])
    let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
    private let gateTimeout: TimeInterval

    init(gateTimeout: TimeInterval = 3) {
        self.gateTimeout = gateTimeout
    }

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot, forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation, onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        let index = calls.withLock { value in defer { value += 1 }; return value }
        cancellations.withLock { $0.append(cancellation) }
        if request.kind == .closeWindow {
            closeGroups.withLock { $0.append(request.windowID.flatMap { snapshot.windows[$0]?.groupID }) }
        }
        guard gates.indices.contains(index), gates[index].wait(timeout: .now() + gateTimeout) == .success,
              !cancellation.isCancelled else { return false }
        effects.withLock { $0.append("\(request.windowID!.rawValue):\(request.kind.rawValue)") }
        return true
    }
}

@MainActor
final class WindowCommandLifecycleTests: XCTestCase {
    private func waitUntil(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func start(_ executor: ControlledWindowExecutor, activeWindowID: String? = nil) async -> AppRuntime {
        let runtime = AppRuntime(tracker: CommandInventory(activeWindowID: activeWindowID), actionExecutor: executor,
                                 isAppFrontmost: { activeWindowID != nil && $0 == 42 })
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
        let runtime = await start(executor, activeWindowID: "review-1")
        runtime.toggle(windowID: "review-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["review-1"]?.status, .minimized)
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let pending = runtime.pendingActionsForTesting
        runtime.stop()
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertTrue(executor.effects.withLock { $0.isEmpty })
    }

    func testNewActivateCancelsOlderMinimizeAndWaitsForItsInFlightCall() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor, activeWindowID: "review-1")
        defer { runtime.stop() }
        runtime.toggle(windowID: "review-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["review-1"]?.status, .minimized)
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
        let runtime = await start(executor, activeWindowID: "review-1")
        runtime.toggle(windowID: "review-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["review-1"]?.status, .minimized)
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
        let runtime = await start(executor, activeWindowID: "review-1")
        runtime.toggle(windowID: "review-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["review-1"]?.status, .minimized)
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

    func testCancelledFinderCaptureDrainsItsNativeReadThenLetsTheNextWindowProceedWithoutRetries() async throws {
        let desktop = BehaviorDesktop(editorBundleIdentifier: "com.apple.finder")
        let gate = BehaviorReadGate(attribute: kAXWindowsAttribute as String)
        let reads = Mutex(0)
        desktop.state.withLock {
            $0.windows[1001]?.status = .minimized
            $0.unreadInventories.insert(-41000)
            $0.beforeInventoryRead = { pid in
                guard pid == -41000 else { return }
                reads.withLock { $0 += 1 }
                gate.read(kAXWindowsAttribute as String)
            }
        }
        let records = desktop.state.withLock { Dictionary(uniqueKeysWithValues: $0.windows.values.map { ($0.id, $0) }) }
        let snapshot = DockSnapshot(windows: records, orderedWindowIDs: records.keys.sorted { $0.rawValue < $1.rawValue })
        let finder = try XCTUnwrap(snapshot.windows[.init(rawValue: "editor-a")])
        let browser = try XCTUnwrap(snapshot.windows[.init(rawValue: "browser-c")])
        let executor = PlatformActionExecutor(
            switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0", "DOCK_FAST_WINDOW_HANDLE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let queue = WindowActionQueue()
        defer { gate.release.signal(); queue.stop() }
        queue.submit(key: finder.id.rawValue) { _, cancellation in
            _ = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                executor.execute(.init(kind: .activateWindow, windowID: finder.id), snapshot: snapshot,
                    forcedMinimizedPrior: true, cancellation: cancellation, onHandoffActivePrediction: nil)
            }
        }
        await waitUntil { gate.entered.withLock { $0 } }
        queue.submit(key: finder.id.rawValue) { _, _ in }
        let completedAt = Mutex<TimeInterval?>(nil)
        queue.submit(key: browser.id.rawValue) { _, cancellation in
            _ = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                let result = executor.execute(.init(kind: .minimizeWindow, windowID: browser.id), snapshot: snapshot,
                    forcedMinimizedPrior: false, cancellation: cancellation, onHandoffActivePrediction: nil)
                completedAt.withLock { $0 = ProcessInfo.processInfo.systemUptime }
                return result
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(completedAt.withLock { $0 }, "The shared queue must drain an admitted native call even after its caller is cancelled")
        let releasedAt = ProcessInfo.processInfo.systemUptime
        gate.release.signal()
        for task in queue.pendingForTesting { await task.value }
        let completion = try XCTUnwrap(completedAt.withLock { $0 })
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(reads.withLock { $0 }, 1)
        print("finder-capture-after-cancellation reads=\(reads.withLock { $0 }) next-window-delay-ms=\((completion - releasedAt) * 1000)")
        XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.status }, .minimized)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["2001:AXMinimized"])
    }
}


extension WindowCommandLifecycleTests {
    private func startWithQueuedClose(
        _ executor: ControlledWindowExecutor
    ) async -> (runtime: AppRuntime, inventory: CommandInventory) {
        let generation = ProcessGeneration(timeval(tv_sec: 1, tv_usec: 0))
        let inventory = CommandInventory(windows: (1...2).map {
            WindowRecord(id: WindowID(rawValue: "cgw-\($0)"), appID: AppID(rawValue: "review"), pid: 42,
                         bundleIdentifier: "test.review", title: "Window", bounds: nil, status: .inactive,
                         cgWindowID: UInt32($0), groupID: "seat-\($0)", processGeneration: generation)
        })
        let runtime = AppRuntime(tracker: inventory, actionExecutor: executor, isAppFrontmost: { _ in false })
        runtime.start()
        await waitUntil { runtime.snapshot.windows.count == 2 }
        runtime.activate(windowID: "cgw-1")
        await waitUntil { executor.cancellations.withLock { $0.count } == 1 }
        runtime.close(windowID: "cgw-2")
        return (runtime, inventory)
    }

    private func publishReplacement(of id: WindowID, inventory: CommandInventory, runtime: AppRuntime) async {
        var next = inventory.values.value
        next.windows[id]?.groupID = "replacement-seat"
        inventory.values.send(next)
        await waitUntil { runtime.snapshot.windows[id]?.groupID == "replacement-seat" }
    }

    func testQueuedCloseIsDiscardedWhenWindowNumberIsReused() async {
        let executor = ControlledWindowExecutor()
        let (runtime, inventory) = await startWithQueuedClose(executor)
        defer { runtime.stop() }
        await publishReplacement(of: WindowID(rawValue: "cgw-2"), inventory: inventory, runtime: runtime)
        let pending = runtime.pendingActionsForTesting
        for gate in executor.gates { gate.signal() }
        for task in pending { await task.value }

        XCTAssertEqual(executor.effects.withLock { $0 }, ["cgw-1:activateWindow"])
        XCTAssertTrue(executor.closeGroups.withLock { $0.isEmpty })
    }

    func testReplacementWindowAcceptsItsOwnCloseWhileWorkerIsBlocked() async {
        let executor = ControlledWindowExecutor()
        let (runtime, inventory) = await startWithQueuedClose(executor)
        defer { runtime.stop() }
        await publishReplacement(of: WindowID(rawValue: "cgw-2"), inventory: inventory, runtime: runtime)
        runtime.close(windowID: "cgw-2")
        let pending = runtime.pendingActionsForTesting
        for gate in executor.gates { gate.signal() }
        for task in pending { await task.value }

        XCTAssertEqual(executor.closeGroups.withLock { $0 }, ["replacement-seat"])
        XCTAssertEqual(executor.effects.withLock { $0 }, ["cgw-1:activateWindow", "cgw-2:closeWindow"])
    }

    func testReplacementDiscardsInFlightActivationStateAndCompletion() async {
        let executor = ControlledWindowExecutor()
        let (runtime, inventory) = await startWithQueuedClose(executor)
        defer { runtime.stop() }
        let id = WindowID(rawValue: "cgw-1")
        await publishReplacement(of: id, inventory: inventory, runtime: runtime)
        XCTAssertEqual(executor.cancellations.withLock { $0.first?.isCancelled }, true)
        XCTAssertNil(runtime.optimisticStatesByWindowID[id.rawValue])
        XCTAssertNil(runtime.debugState.feedbackEntriesByWindowID[id.rawValue])
        let pending = runtime.pendingActionsForTesting
        for gate in executor.gates { gate.signal() }
        for task in pending { await task.value }

        XCTAssertNil(runtime.debugState.feedbackEntriesByWindowID[id.rawValue])
        XCTAssertEqual(executor.effects.withLock { $0 }, ["cgw-2:closeWindow"])
    }

    func testQueuedCloseSurvivesTitleStatusAndFrameChanges() async {
        let executor = ControlledWindowExecutor()
        let (runtime, inventory) = await startWithQueuedClose(executor)
        defer { runtime.stop() }
        let id = WindowID(rawValue: "cgw-2")
        var next = inventory.values.value
        next.windows[id]?.title = "Renamed"
        next.windows[id]?.status = .minimized
        next.windows[id]?.bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        inventory.values.send(next)
        await waitUntil { runtime.snapshot.windows[id]?.title == "Renamed" }
        let pending = runtime.pendingActionsForTesting
        for gate in executor.gates { gate.signal() }
        for task in pending { await task.value }

        XCTAssertEqual(executor.closeGroups.withLock { $0 }, ["seat-2"])
        XCTAssertEqual(executor.effects.withLock { $0 }, ["cgw-1:activateWindow", "cgw-2:closeWindow"])
    }

    func testRepeatedCloseDoesNotCancelAnAdmittedClose() async {
        let executor = ControlledWindowExecutor()
        let runtime = await start(executor)
        defer { runtime.stop() }
        runtime.close(windowID: "review-1")
        await waitUntil { executor.cancellations.withLock { $0.count } == 1 }
        runtime.close(windowID: "review-1")
        XCTAssertFalse(executor.cancellations.withLock { $0[0].isCancelled })
        let pending = runtime.pendingActionsForTesting
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
        XCTAssertEqual(executor.effects.withLock { $0 }, ["review-1:closeWindow"])
    }

    func testRepeatedCloseAfterFeedbackExpiresKeepsTheOriginalQueuePosition() async {
        let executor = ControlledWindowExecutor(gateTimeout: 12)
        let runtime = await start(executor)
        defer { runtime.stop() }
        runtime.activate(windowID: "review-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        runtime.close(windowID: "review-2")
        runtime.close(windowID: "review-1")
        await waitUntil(timeout: .seconds(7)) {
            runtime.debugState.feedbackEntriesByWindowID["review-2"]?.phase != .pending
        }

        runtime.close(windowID: "review-2")
        let pending = runtime.pendingActionsForTesting
        for gate in executor.gates { gate.signal() }
        for task in pending { await task.value }

        XCTAssertEqual(executor.effects.withLock { $0 }, ["review-2:closeWindow", "review-1:closeWindow"])
    }

    func testCloseReplacesAnEarlierPendingActivationOrMinimize() async {
        for minimize in [false, true] {
            let executor = ControlledWindowExecutor()
            let runtime = await start(executor, activeWindowID: minimize ? "review-1" : nil)
            defer { runtime.stop() }
            if minimize { runtime.toggle(windowID: "review-1") }
            else { runtime.activate(windowID: "review-1") }
            await waitUntil { executor.calls.withLock { $0 } == 1 }
            runtime.close(windowID: "review-1")
            XCTAssertTrue(executor.cancellations.withLock { $0[0].isCancelled })
            let pending = runtime.pendingActionsForTesting
            for gate in executor.gates { gate.signal() }
            for task in pending { await task.value }
            XCTAssertEqual(executor.effects.withLock { $0 }, ["review-1:closeWindow"])
        }
    }
}
