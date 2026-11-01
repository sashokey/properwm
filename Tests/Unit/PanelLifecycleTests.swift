import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

@MainActor
private final class PanelInventory: WindowInventoryTracking {
    var snapshots: AnyPublisher<DockSnapshot, Never> { Just(DockSnapshot.empty).eraseToAnyPublisher() }
    func start() {}
    func stop() {}
}

@MainActor
final class PanelLifecycleTests: XCTestCase {
    private func coordinator() -> PanelCoordinator {
        PanelCoordinator(placement: .primary, overlaySpaceHost: nil, runtime: AppRuntime(tracker: PanelInventory()),
            stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
                physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)),
            screenProvider: { [] }, mainScreenProvider: { nil })
    }

    func testPanelCreationAndPlacementWaitForAnAvailableScreen() {
        let coordinator = coordinator()
        XCTAssertFalse(coordinator.start())
        XCTAssertNil(coordinator.dockPanel)
        XCTAssertNil(coordinator.currentScreen)
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        XCTAssertNil(coordinator.panelCurrentScreen(panel: panel))
        coordinator.dockPanel = panel
        coordinator.relayout(animated: false)
        XCTAssertFalse(panel.isVisible)
        coordinator.tearDown()
    }

    func testUnknownFullscreenNeverClearsLastKnownFullscreen() {
        let coordinator = coordinator()
        coordinator.visibilityState.setFullscreen(true)
        coordinator.fullscreenProbeGeneration = 2
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 2, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test")
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil), request: request)
        XCTAssertFalse(coordinator.visibilityState.isVisible)
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil), request: request)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
    }

    func testFullscreenWorkerCoalescesBurstAndDoesNotPublishAfterStop() async {
        let calls = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        var results: [UInt64] = []
        let worker = FullscreenProbeWorker(read: { _ in
            calls.withLock { $0 += 1 }
            _ = gate.wait(timeout: .now() + 2)
            return FullscreenAXProbe(verdict: .fullscreen, overlayWindowID: nil)
        }, deliver: { request, _ in results.append(request.generation) })
        for generation in 1...20 {
            worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: UInt64(generation),
                                                  spaceGeneration: nil, finalConfirmation: false, source: "test"))
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while calls.withLock({ $0 }) == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        gate.signal()
        while calls.withLock({ $0 }) < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertTrue(results.isEmpty)
        let pending = worker.pendingWorkForTesting
        worker.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertTrue(results.isEmpty)
    }

    func testPeriodicFullscreenCheckRunsWhileVisibleAndCompletesAPendingHold() async {
        let coordinator = coordinator()
        coordinator.fullscreenFrameProvider = { CGRect(x: 0, y: 0, width: 100, height: 100) }
        let reads = Mutex(0)
        var requests: [FullscreenProbeRequest] = []
        coordinator.fullscreenProbeWorker = FullscreenProbeWorker(read: { _ in
            reads.withLock { $0 += 1 }
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, deliver: { [weak coordinator] request, probe in
            requests.append(request)
            coordinator?.receiveFullscreenProbe(probe, request: request)
        })
        coordinator.reconcileFullscreenState()
        let deadline = ContinuousClock.now + .seconds(2)
        while requests.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(reads.withLock { $0 }, 1)
        coordinator.visibilityState.setFullscreen(true)
        coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 7, pid: 42, screenCGFrame: coordinator.currentPanelScreenCGFrame())
        coordinator.reconcileFullscreenState()
        while requests.count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(requests.last?.spaceGeneration, 7)
        XCTAssertEqual(requests.last?.finalConfirmation, true)
        XCTAssertNil(coordinator.fullscreenSpaceHold)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testDisplayDisconnectAndReconnectRebuildUnitsWithoutShowingPanels() {
        var snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        var starts = 0
        let orchestrator = TaskbarScreenOrchestrator(runtime: AppRuntime(tracker: PanelInventory()),
            stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: snapshot),
            topologySnapshotProvider: { snapshot }, startCoordinator: { _ in starts += 1; return true })
        orchestrator.start()
        XCTAssertTrue(orchestrator.units.isEmpty)
        snapshot = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"], attributionTable: .empty)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(orchestrator.units.map(\.key), ["A", "B"])
        XCTAssertEqual(starts, 2)
        snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(orchestrator.units.isEmpty)
        orchestrator.suspendAndRelease()
    }
}
