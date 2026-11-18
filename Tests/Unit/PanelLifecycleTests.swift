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
    func testScreenOrchestratorDoesNotStartAFullscreenTimerForEachPanel() {
        let topology = ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"], attributionTable: .empty
        )
        let orchestrator = TaskbarScreenOrchestrator(
            runtime: AppRuntime(tracker: PanelInventory()), stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology),
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, pollInterval: 0),
            overlaySpaceHost: nil, topologySnapshotProvider: { topology }, startCoordinator: { panel in
                panel.setupFullscreenMonitor()
                return true
            }
        )
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        XCTAssertEqual(orchestrator.units.count, 2)
        XCTAssertTrue(orchestrator.units.allSatisfy { $0.coordinator.fullscreenReconcileTimer == nil })
    }

    func testSpaceChangeSharesOneFreshFullscreenCGCaptureAcrossPanels() throws {
        let leftFrame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let rightFrame = leftFrame.offsetBy(dx: leftFrame.width, dy: 0)
        func window(on frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
             kCGWindowLayer as String: 0, kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        var windows: [[String: Any]]? = [window(on: leftFrame)]
        var captures = 0
        let topology = ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"], attributionTable: .empty
        )
        let orchestrator = TaskbarScreenOrchestrator(
            runtime: AppRuntime(tracker: PanelInventory()), stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology),
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0),
            overlaySpaceHost: nil, topologySnapshotProvider: { topology },
            startCoordinator: { panel in
                let frame = panel.fixedDisplayUUID == "left" ? leftFrame : rightFrame
                panel.fullscreenFrameProvider = { frame }
                return true
            },
            captureFullscreenCGWindows: {
                captures += 1
                return windows
            }
        )
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        let left = try XCTUnwrap(orchestrator.units.first(where: { $0.key == "left" })?.coordinator)
        let right = try XCTUnwrap(orchestrator.units.first(where: { $0.key == "right" })?.coordinator)
        let notifications = NSWorkspace.shared.notificationCenter
        let spaceChanged = NSWorkspace.activeSpaceDidChangeNotification

        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(left.visibilityState.isVisible)
        XCTAssertTrue(right.visibilityState.isVisible)

        windows = nil
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(captures, 2)
        XCTAssertFalse(left.visibilityState.isVisible)
        XCTAssertTrue(right.visibilityState.isVisible)

        windows = [window(on: rightFrame)]
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(captures, 3)
        XCTAssertFalse(right.visibilityState.isVisible)

        left.fullscreenFrameProvider = { nil }
        right.fullscreenFrameProvider = { nil }
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(captures, 3)
    }

    func testSharedFullscreenReadClassifiesTheSameObservationSeparatelyForEachScreen() async {
        let reads = Mutex(0)
        let left = CGRect(x: 0, y: 0, width: 600, height: 500)
        let right = left.offsetBy(dx: left.width, dy: 0)
        let batch = FullscreenAXReadBatch { _ in
            reads.withLock { $0 += 1 }
            return .window(role: kAXWindowRole as String, isFullscreen: false, frame: left, id: 10, layer: 0)
        }
        async let leftResult = Task.detached { batch.observation(for: 42).probe(on: left) }.value
        async let rightResult = Task.detached { batch.observation(for: 42).probe(on: right) }.value
        let (leftProbe, rightProbe) = await (leftResult, rightResult)
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertEqual(leftProbe.verdict, .fullscreen)
        XCTAssertEqual(leftProbe.overlayWindowID, 10)
        XCTAssertEqual(rightProbe.verdict, .notOnThisScreen)
        XCTAssertNil(rightProbe.overlayWindowID)
    }

    func testDelayedPanelRefreshesAnExpiredSharedFullscreenObservation() {
        let reads = Mutex(0)
        let now = Mutex<TimeInterval>(10)
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let window = CGRect(x: 20, y: 20, width: 500, height: 400)
        let batch = FullscreenAXReadBatch(uptime: { now.withLock { $0 } }) { _ in
            reads.withLock { count in
                count += 1
                return count == 1
                    ? .window(role: kAXWindowRole as String, isFullscreen: true, frame: screen, id: nil, layer: nil)
                    : .window(role: kAXWindowRole as String, isFullscreen: false, frame: window, id: nil, layer: nil)
            }
        }
        XCTAssertEqual(batch.observation(for: 42).probe(on: screen).verdict, .fullscreen)
        now.withLock { $0 += 1 }
        XCTAssertEqual(batch.observation(for: 42).probe(on: screen).verdict, .windowed)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    private func coordinator(placement: TaskbarUnitPlacement = .primary) -> PanelCoordinator {
        let coordinator = PanelCoordinator(placement: placement, overlaySpaceHost: nil, runtime: AppRuntime(tracker: PanelInventory()),
            stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
                physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)),
            screenProvider: { [] }, mainScreenProvider: { nil })
        coordinator.fullscreenFrameProvider = { .zero }
        return coordinator
    }

    func testPanelCreationAndPlacementWaitForAnAvailableScreen() {
        let coordinator = coordinator()
        XCTAssertFalse(coordinator.start())
        XCTAssertNil(coordinator.dockPanel)
        XCTAssertNil(coordinator.currentScreen)
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        XCTAssertNil(coordinator.panelCurrentScreen(panel: panel))
        coordinator.dockPanel = panel
        coordinator.relayout()
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

    func testFinalSpaceHoldReleasesWithConfirmedDesktopAndWindowedCGWhenAXIsUnknown() async {
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let otherScreen = screen.offsetBy(dx: screen.width, dy: 0)
        func window(_ id: UInt32, _ frame: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: -42,
             kCGWindowLayer as String: layer, kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let desktopWindows = [window(10, CGRect(x: 10, y: 20, width: 500, height: 450)),
                              window(11, otherScreen), window(12, screen, layer: -1)]
        let stillFullscreen = desktopWindows + [window(13, screen, layer: 2)]
        let cases: [(String, Bool?, [[String: Any]]?, Bool)] = [
            ("confirmed desktop", false, desktopWindows, true),
            ("empty desktop", false, [], true),
            ("window list failed", false, nil, false),
            ("display Space unavailable", nil, desktopWindows, false),
            ("native fullscreen Space", true, desktopWindows, false),
            ("screen-sized overlay still present", false, stillFullscreen, false)
        ]
        for (label, space, windows, expectedVisible) in cases {
            let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
            defer { coordinator.tearDown() }
            coordinator.fullscreenFrameProvider = { screen }
            coordinator.fullscreenCGWindowsProvider = { windows }
            coordinator.visibilityState.setFullscreen(true)
            coordinator.lastActiveApplicationPID = 42
            var confirmed = false
            coordinator.fullscreenProbeWorker = FullscreenProbeWorker(read: { _ in
                FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
            }, readSpace: { $0.displayUUID == "left" ? space : nil }, deliver: { [weak coordinator] request, probe in
                coordinator?.receiveFullscreenProbe(probe, request: request)
                if request.finalConfirmation { confirmed = true }
            })

            coordinator.handleSpaceChange()
            XCTAssertFalse(coordinator.visibilityState.isVisible, label)
            coordinator.fullscreenSpaceHoldTimer?.fire()
            let deadline = ContinuousClock.now + .seconds(2)
            while !confirmed, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(confirmed, label)
            XCTAssertEqual(coordinator.visibilityState.isVisible, expectedVisible, label)
        }
    }

    func testActivationWithoutFocusedWindowKeepsPanelHiddenWhenDisplaySpaceIsUnknown() async throws {
        let coordinator = coordinator(placement: .fixed(displayUUID: "right"))
        defer { coordinator.tearDown() }
        coordinator.fullscreenFrameProvider = { nil }
        coordinator.fullscreenSpaceProvider = { _ in nil }
        coordinator.fullscreenCGWindowsProvider = { [] }
        coordinator.setupFullscreenMonitor()
        let worker = try XCTUnwrap(coordinator.fullscreenProbeWorker)
        coordinator.fullscreenFrameProvider = { CGRect(x: 600, y: 0, width: 600, height: 500) }
        coordinator.visibilityState.setFullscreen(true)

        coordinator.handleAppActivated(pid: nil, sharedRead: FullscreenAXReadBatch { _ in .unknown })
        let confirmation = try XCTUnwrap(coordinator.fullscreenSpaceHoldTimer)
        confirmation.fire()
        while let work = worker.pendingWorkForTesting.first { await work.value }

        XCTAssertFalse(coordinator.visibilityState.isVisible)
    }

    func testSystemFocusCannotRevealThePanelWhileItsDisplayRemainsInAFullscreenSpace() {
        let coordinator = coordinator()
        coordinator.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: true, source: "system-focus")
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil, spaceVerdict: true), request: request)
        XCTAssertFalse(coordinator.visibilityState.isVisible)
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil, spaceVerdict: false), request: request)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testFullscreenCallbackDoesNotSynchronouslyReadManagedSpaces() {
        let coordinator = coordinator()
        coordinator.fullscreenProbeGeneration = 1
        let reads = Mutex(0)
        coordinator.fullscreenSpaceProvider = { _ in
            reads.withLock { $0 += 1 }
            return true
        }
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil), request: request)

        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testFullscreenWorkerReadsFreshSpacesOffMainThreadAndAppliesBothTransitions() async {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        coordinator.fullscreenFrameProvider = { .zero }
        let reads = Mutex<[Bool]>([])
        let fullSpace = Mutex(true)
        var delivered = 0
        let worker = FullscreenProbeWorker(read: { _ in
            FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, readSpace: { request in
            guard request.displayUUID == "left" else { return nil }
            reads.withLock { $0.append(Thread.isMainThread) }
            return fullSpace.withLock { $0 }
        }, deliver: { request, probe in
            delivered += 1
            coordinator.receiveFullscreenProbe(probe, request: request)
        })
        coordinator.fullscreenProbeGeneration = 1
        worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
            finalConfirmation: false, source: "test", displayUUID: "left"))
        let firstDeadline = ContinuousClock.now + .seconds(2)
        while delivered < 1, ContinuousClock.now < firstDeadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(coordinator.visibilityState.isVisible)

        fullSpace.withLock { $0 = false }
        coordinator.fullscreenProbeGeneration = 2
        worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 2, spaceGeneration: nil,
            finalConfirmation: false, source: "test", displayUUID: "left"))
        let secondDeadline = ContinuousClock.now + .seconds(2)
        while delivered < 2, ContinuousClock.now < secondDeadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(delivered, 2)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        XCTAssertEqual(reads.withLock { $0 }, [false, false])
        worker.stop()
        coordinator.tearDown()
    }

    func testLateFullscreenSpaceResultCannotApplyToANewerProbeGeneration() async {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        coordinator.fullscreenFrameProvider = { .zero }
        coordinator.fullscreenProbeGeneration = 1
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        var delivered = 0
        let worker = FullscreenProbeWorker(read: { _ in
            FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }, readSpace: { _ in
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 2)
            return true
        }, deliver: { request, probe in
            delivered += 1
            coordinator.receiveFullscreenProbe(probe, request: request)
        })
        defer { gate.signal(); worker.stop(); coordinator.tearDown() }
        worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: 3,
            finalConfirmation: false, source: "test", displayUUID: "left"))
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(entered.withLock { $0 })
        coordinator.fullscreenProbeGeneration = 2
        gate.signal()
        while delivered == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
    }

    func testFullscreenSpaceResultCannotApplyAfterDisplayGeometryChanges() {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        coordinator.fullscreenFrameProvider = { CGRect(x: 100, y: 0, width: 100, height: 100) }
        coordinator.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
            finalConfirmation: false, source: "test", displayUUID: "left")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil, spaceVerdict: true), request: request)

        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testWindowedSpaceResultCannotClearANewerFullscreenHold() {
        let coordinator = coordinator()
        coordinator.visibilityState.setFullscreen(true)
        coordinator.fullscreenProbeGeneration = 2
        coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 4, pid: 42, screenCGFrame: .zero)
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 2, spaceGeneration: 3,
            finalConfirmation: true, source: "test")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil, spaceVerdict: false), request: request)

        XCTAssertFalse(coordinator.visibilityState.isVisible)
        XCTAssertEqual(coordinator.fullscreenSpaceHold?.generation, 4)
        coordinator.tearDown()
    }

    func testResidentPanelUsesNativeMissionControlHidingWithoutDesktopPresentation() {
        let coordinator = coordinator()
        let panel = NonConstrainingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        coordinator.configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.isVisible)
        coordinator.tearDown()
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

    func testDesktopSpaceChangeDismissesAnOpenPopupSynchronously() {
        let coordinator = coordinator()
        coordinator.panelsAreVisible = false
        let popup = BehaviorPopup()
        let view = TaskbarView(frame: .zero, popup: popup, contextMenu: BehaviorMenu())
        coordinator.taskbarView = view
        popup.present(content: NSView(), frame: .zero, anchorWindow: nil)
        XCTAssertTrue(popup.isPresented)
        XCTAssertTrue(coordinator.visibilityState.isVisible)

        coordinator.handleSpaceChange()

        XCTAssertFalse(popup.isPresented)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testGeometryProbeCanCompleteTheExpiredFullscreenHold() async {
        let coordinator = coordinator()
        coordinator.visibilityState.setFullscreen(true)
        let requests = Mutex<[FullscreenProbeRequest]>([])
        let unblockFirstProbe = DispatchSemaphore(value: 0)
        var delivered: [FullscreenProbeRequest] = []
        coordinator.fullscreenProbeWorker = FullscreenProbeWorker(read: { request in
            let first = requests.withLock {
                $0.append(request)
                return $0.count == 1
            }
            if first { _ = unblockFirstProbe.wait(timeout: .now() + 3) }
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, deliver: { [weak coordinator] request, probe in
            delivered.append(request)
            coordinator?.receiveFullscreenProbe(probe, request: request)
        })
        defer {
            unblockFirstProbe.signal()
            coordinator.tearDown()
        }

        coordinator.handleAppActivated(pid: 42)
        let holdGeneration = coordinator.fullscreenSpaceHold?.generation
        XCTAssertNotNil(holdGeneration)
        coordinator.fullscreenSpaceHoldTimer?.fire()
        let deadline = ContinuousClock.now + .seconds(2)
        while coordinator.fullscreenSpaceHoldTimer != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(coordinator.fullscreenSpaceHoldTimer)

        coordinator.windowGeometryChanged()
        let latestGeneration = coordinator.fullscreenProbeGeneration
        unblockFirstProbe.signal()
        while delivered.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(delivered.map(\.generation), [latestGeneration])
        XCTAssertEqual(delivered.first?.spaceGeneration, holdGeneration)
        XCTAssertNil(coordinator.fullscreenSpaceHold)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
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
        coordinator.lastActiveApplicationPID = 42
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
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0),
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

extension PanelLifecycleTests {
    func testFullscreenResultRejectsChangedGeometryWhenDisplayUUIDIsUnavailable() {
        let coordinator = coordinator()
        coordinator.fullscreenFrameProvider = { CGRect(x: 100, y: 0, width: 100, height: 100) }
        coordinator.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            generation: 1, spaceGeneration: nil, finalConfirmation: false, source: "test")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .fullscreen, overlayWindowID: nil), request: request)

        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }
}
