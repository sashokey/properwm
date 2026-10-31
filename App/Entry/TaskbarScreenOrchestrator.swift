import AppKit
import Combine
import Foundation
import os

@MainActor
final class TaskbarScreenOrchestrator: NSObject, WindowLiftAvoidanceHost {
    struct Unit {
        let key: String?
        let coordinator: PanelCoordinator
    }

    private(set) var units: [Unit] = []
    let overlaySpaceHost = OverlaySpaceHost.make()

    private let runtime: AppRuntime
    private let stripOrderStore: StripOrderStore
    private let settingsStore: AppSettingsStore
    private let displayTopologyStore: DisplayTopologyStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let topologyRetryScheduler: DisplayTopologyRefreshController.ScheduleAfter
    private let logger = Logger(subsystem: "io.github.sashokey.properwm", category: "taskbar-screens")

    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var fullscreenIntentMonitor: FullscreenIntentMonitor?
    private var topologyRefreshController: DisplayTopologyRefreshController?

    private var menuTrackingDepth = 0

    init(
        runtime: AppRuntime,
        stripOrderStore: StripOrderStore,
        settingsStore: AppSettingsStore,
        displayTopologyStore: DisplayTopologyStore,
        topologySnapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot = {
            DisplayIdentity.topologySnapshot()
        },
        topologyRetryScheduler: @escaping DisplayTopologyRefreshController.ScheduleAfter = { delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    ) {
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.settingsStore = settingsStore
        self.displayTopologyStore = displayTopologyStore
        self.topologySnapshotProvider = topologySnapshotProvider
        self.topologyRetryScheduler = topologyRetryScheduler
        super.init()
    }

    isolated deinit {
        topologyRefreshController?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !started else { return }
        started = true
        let seedController = makeTopologyRefreshController()
        topologyRefreshController = seedController
        let snapshot = seedController.prepareForTopologyChange()
        rebuildUnits(reason: "start", connectedKeys: snapshot.identifiedDisplayUUIDs)
        observeMenuTracking()
        reconcileFullscreenIntentMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func suspendAndRelease() {
        guard !isSuspended else { return }
        isSuspended = true
        fullscreenIntentMonitor?.stop()
        fullscreenIntentMonitor = nil
        for unit in units {
            unit.coordinator.setFullscreenIntentRouting(enabled: false)
            unit.coordinator.tearDown()
        }
        units = []
        overlaySpaceHost?.tearDown()
        topologyRefreshController?.cancel()
        topologyRefreshController = nil
        NotificationCenter.default.removeObserver(self)
    }

    func setTaskbarMenuOpen(_ open: Bool) {
        units.forEach { $0.coordinator.setTaskbarMenuOpen(open) }
    }

    private func rebuildUnits(reason: String, connectedKeys: [String]) {
        guard started, !isSuspended else { return }
        let desired = TaskbarDisplaySet.desiredUnitKeys(
            connectedKeys: connectedKeys
        )
        let current = units.map(\.key)
        guard desired != current else { return }
        let desiredSet = Set(desired.map { $0 ?? "" })
        var survivors: [String?: Unit] = [:]
        for unit in units {
            if desiredSet.contains(unit.key ?? "") {
                survivors[unit.key] = unit
            } else {
                unit.coordinator.setFullscreenIntentRouting(enabled: false)
                unit.coordinator.tearDown()
            }
        }
        units = desired.map { key in survivors[key] ?? makeUnit(key: key) }
        logger.info("units rebuilt reason=\(reason, privacy: .public) count=\(self.units.count, privacy: .public)")
        pushPanelScreensToIntentMonitor()
    }

    private func makeUnit(key: String?) -> Unit {
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .primary
        let coordinator = PanelCoordinator(
            placement: placement,
            overlaySpaceHost: overlaySpaceHost,
            runtime: runtime,
            stripOrderStore: stripOrderStore,
            settingsStore: settingsStore,
            displayTopologyStore: displayTopologyStore
        )
        coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu
        coordinator.onPanelScreenChanged = { [weak self] in self?.pushPanelScreensToIntentMonitor() }
        coordinator.onAccessoryWillOpen = { [weak self] unit, kind in
            self?.closeAccessories(exceptFor: unit, opening: kind)
        }
        coordinator.start()
        coordinator.setFullscreenIntentRouting(enabled: fullscreenIntentMonitor != nil)
        return Unit(key: key, coordinator: coordinator)
    }



    private func unitContainingMouse() -> Unit? {
        let mouse = NSEvent.mouseLocation
        return units.first { $0.coordinator.currentScreen?.frame.contains(mouse) == true }
    }

    private func unit(forDisplayUUID uuid: String) -> Unit? {
        if let unit = units.first(where: { $0.key == uuid }) { return unit }
        return units.first { unit in
            unit.coordinator.currentScreen.flatMap { DisplayIdentity.uuidString(for: $0) } == uuid
        }
    }

    @objc private func screenParametersChanged() {
        let snapshot: ScreenTopologySnapshot
        if let seedController = topologyRefreshController {
            snapshot = seedController.prepareForTopologyChange()
        } else {
            snapshot = topologySnapshotProvider()
            displayTopologyStore.apply(snapshot)
        }
        rebuildUnits(reason: "screens", connectedKeys: snapshot.identifiedDisplayUUIDs)
        units.forEach { $0.coordinator.screenParametersChanged() }
        pushPanelScreensToIntentMonitor()
    }

    private func makeTopologyRefreshController() -> DisplayTopologyRefreshController {
        DisplayTopologyRefreshController(
            snapshotProvider: topologySnapshotProvider,
            applySnapshot: { [weak displayTopologyStore] snapshot in
                displayTopologyStore?.apply(snapshot)
            },
            onRetrySnapshot: { [weak self] snapshot in
                self?.rebuildUnits(
                    reason: "topology-retry",
                    connectedKeys: snapshot.identifiedDisplayUUIDs
                )
                self?.units.forEach { $0.coordinator.screenParametersChanged() }
                self?.pushPanelScreensToIntentMonitor()
            },
            scheduleAfter: topologyRetryScheduler
        )
    }

    private func closeAccessories(exceptFor unit: PanelCoordinator, opening kind: PanelCoordinator.AccessoryKind) {
        for other in units where other.coordinator !== unit {
            other.coordinator.dismissTaskbarPopups()
        }
    }

    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] {
        units.compactMap { $0.coordinator.windowLiftAvoidanceContext() }
    }

    private func reconcileFullscreenIntentMonitor() {
        let enabled = FullscreenIntentDecision.isEnabled(
            settingEnabled: settingsStore.fullscreenIntentEnabled,
            environment: ProcessInfo.processInfo.environment
        )
        guard enabled, !isSuspended else {
            fullscreenIntentMonitor?.stop()
            fullscreenIntentMonitor = nil
            units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: false) }
            return
        }
        guard fullscreenIntentMonitor == nil else { return }
        let monitor = FullscreenIntentMonitor(
            onIntent: { [weak self] request in
                self?.units.forEach { $0.coordinator.beginFullscreenIntent(request) }
            },
            onSpaceSwitchIntent: { [weak self] direction, displayUUID in
                guard let self else { return }
                let target = self.unit(forDisplayUUID: displayUUID) ?? self.unitContainingMouse() ?? self.units.first
                target?.coordinator.beginFullscreenSpaceIntent(direction: direction)
            },
            onContextChange: { [weak self] change in
                self?.units.forEach { $0.coordinator.handleFullscreenIntentContextChange(change) }
            }
        )
        fullscreenIntentMonitor = monitor
        monitor.updatePanelScreens(currentPanelScreenCGFrames)
        monitor.start()
        units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: true) }
    }

    private var currentPanelScreenCGFrames: [CGRect] {
        units.compactMap { $0.coordinator.currentPanelScreenCGFrame() }
            .reduce(into: [CGRect]()) { unique, frame in
                if !unique.contains(frame) { unique.append(frame) }
            }
    }

    private func pushPanelScreensToIntentMonitor() {
        fullscreenIntentMonitor?.updatePanelScreens(currentPanelScreenCGFrames)
    }

    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func menuTrackingDidBegin() {
        menuTrackingDepth += 1
        guard menuTrackingDepth == 1 else { return }
        setTaskbarMenuOpen(true)
    }

    @objc private func menuTrackingDidEnd() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        setTaskbarMenuOpen(false)
    }

}
