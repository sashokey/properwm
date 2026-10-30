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
    let dragController: DragController
    let overlaySpaceHost = OverlaySpaceHost.make()

    private let runtime: AppRuntime
    private let stripOrderStore: StripOrderStore
    private let settingsStore: AppSettingsStore
    private let displayTopologyStore: DisplayTopologyStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let topologyRetryScheduler: DisplayTopologyRefreshController.ScheduleAfter
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "taskbar-screens")

    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var fullscreenIntentMonitor: FullscreenIntentMonitor?
    private var topologyRefreshController: DisplayTopologyRefreshController?

    private var hoverLocalMouseMonitor: Any?
    private var hoverGlobalMouseMonitor: Any?
    private var hoverPollThrottle = HoverPollThrottle(minInterval: 1.0 / 30.0)
    private var menuTrackingDepth = 0
    private var menuTrackingPollTimer: Timer?
    private static let menuHoverSuspensionEnabled = DebugSwitch.menuHoverSuspend.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let hoverMonitorLeanEnabled = DebugSwitch.hoverMonitorLean.isEnabled(in: ProcessInfo.processInfo.environment)

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
        self.dragController = DragController(screensProvider: { NSScreen.screens })
        super.init()
        wireDragController()
    }

    deinit {
        MainActor.assumeIsolated {
            topologyRefreshController?.cancel()
            removeHoverMouseMonitorsOnly()
        }
        menuTrackingPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !started else { return }
        started = true
        let seedController = makeTopologyRefreshController()
        topologyRefreshController = seedController
        let snapshot = seedController.prepareForTopologyChange()
        rebuildUnits(reason: "start", connectedKeys: snapshot.identifiedDisplayUUIDs)
        DispatchQueue.main.async { [weak dragController] in
            dragController?.prewarmCarrier()
        }
        observeMenuTracking()
        reconcileHoverMouseMonitors()
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
        cancelInteractiveHeightResize()
        setSettingsHeightSessionActive(false)
        dragController.cancelDrag()
        dragController.closeCarrierSurfaces()
        removeHoverMouseMonitors()
        stopMenuTrackingPoll()
        fullscreenIntentMonitor?.stop()
        fullscreenIntentMonitor = nil
        for unit in units {
            unit.coordinator.setFullscreenIntentRouting(enabled: false)
            unit.coordinator.tearDown()
        }
        units = []
        topologyRefreshController?.cancel()
        topologyRefreshController = nil
        NotificationCenter.default.removeObserver(self)
    }

    func setTaskbarMenuOpen(_ open: Bool) {
        units.forEach { $0.coordinator.setTaskbarMenuOpen(open) }
    }

    private func rebuildUnits(reason: String, connectedKeys: [String]) {
        guard started, !isSuspended else { return }
        cancelInteractiveHeightResize()
        let desired = TaskbarDisplaySet.desiredUnitKeys(
            placement: settingsStore.taskbarScreenPlacement,
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
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .followSettings
        let coordinator = PanelCoordinator(
            placement: placement,
            dragController: dragController,
            overlaySpaceHost: overlaySpaceHost,
            runtime: runtime,
            stripOrderStore: stripOrderStore,
            settingsStore: settingsStore,
            displayTopologyStore: displayTopologyStore
        )
        coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu
        coordinator.onHoverMonitorsNeedReconcile = { [weak self] in self?.reconcileHoverMouseMonitors() }
        coordinator.onPanelScreenChanged = { [weak self] in self?.pushPanelScreensToIntentMonitor() }
        coordinator.onAccessoryWillOpen = { [weak self] unit, kind in
            self?.closeAccessories(exceptFor: unit, opening: kind)
        }
        coordinator.onInteractiveHeightResizeSession = { [weak self, weak coordinator] active in
            guard let self else { return }
            self.heightResizeOrigin = active ? coordinator : nil
            self.units.forEach { $0.coordinator.setInteractiveHeightResizeActive(active) }
        }
        coordinator.start()
        coordinator.setFullscreenIntentRouting(enabled: fullscreenIntentMonitor != nil)
        if heightResizeOrigin != nil || settingsHeightSessionActive {
            coordinator.setInteractiveHeightResizeActive(true)
        }
        coordinator.onInteractiveHeightResizeUpdate = { [weak self] in
            self?.units.forEach { $0.coordinator.commitInteractivePanelHeight() }
        }
        return Unit(key: key, coordinator: coordinator)
    }

    private weak var heightResizeOrigin: PanelCoordinator?

    private func cancelInteractiveHeightResize() {
        heightResizeOrigin?.cancelInteractiveResize()
        heightResizeOrigin = nil
    }

    private var settingsHeightSessionActive = false
    private weak var settingsHeightSessionWakeUnit: PanelCoordinator?

    func setSettingsHeightSessionActive(_ active: Bool) {
        guard settingsHeightSessionActive != active else { return }
        if !active { commitSettingsPanelHeight() }
        settingsHeightSessionActive = active
        if active {
            cancelInteractiveHeightResize()
            let wakeUnit = (unitContainingMouse() ?? units.first)?.coordinator
            settingsHeightSessionWakeUnit = wakeUnit
            units.forEach { $0.coordinator.setInteractiveHeightResizeActive(true) }
            wakeUnit?.setAutoHideInhibitor(.interactiveResize, active: true)
        } else {
            settingsHeightSessionWakeUnit?.setAutoHideInhibitor(.interactiveResize, active: false)
            settingsHeightSessionWakeUnit = nil
            units.forEach { $0.coordinator.setInteractiveHeightResizeActive(false) }
        }
    }

    func commitSettingsPanelHeight() {
        guard settingsHeightSessionActive, heightResizeOrigin == nil else { return }
        units.forEach { $0.coordinator.commitInteractivePanelHeight() }
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
        dragController.cancelDrag()   // 切屏/分辨率变 → 取消进行中的跨面板拖动，免得载体留在旧屏坐标
        cancelInteractiveHeightResize()   // same for a height drag: its start point is in old screen coordinates
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
        reconcileHoverMouseMonitors()  // 屏幕数量变了：单屏↔多屏切换监视器是否还有存在的必要
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
            other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
    }

    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] {
        units.compactMap { $0.coordinator.windowLiftAvoidanceContext() }
    }

    private func wireDragController() {
        dragController.pinCarrierWindows = { [weak self] numbers in
            guard let host = self?.overlaySpaceHost else { return }
            _ = host.pin(windowNumbers: numbers)
        }
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

    private var hoverMonitorsNeeded: Bool {
        guard Self.hoverMonitorLeanEnabled else { return true }
        return (NSScreen.screens.count > 1 && settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching)
            || settingsStore.edgeAutoHideEnabled
            || PanelCoordinator.edgeHoverTraceEnabled
    }

    private func reconcileHoverMouseMonitors() {
        guard started, !isSuspended else { return }
        guard menuTrackingDepth == 0 else { return }   // 菜单跟踪期间由挂起逻辑接管
        if hoverMonitorsNeeded {
            installHoverMouseMonitors()
            pollAllUnits()
        } else {
            removeHoverMouseMonitors()
        }
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
        guard Self.menuHoverSuspensionEnabled else { return }
        removeHoverMouseMonitorsOnly()
        startMenuTrackingPollIfNeeded()
    }

    @objc private func menuTrackingDidEnd() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        setTaskbarMenuOpen(false)
        stopMenuTrackingPoll()
        reconcileHoverMouseMonitors()
    }

    private func startMenuTrackingPollIfNeeded() {
        guard menuTrackingPollTimer == nil, started, !isSuspended, hoverMonitorsNeeded else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAllUnits() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTrackingPollTimer = timer
    }

    private func stopMenuTrackingPoll() {
        menuTrackingPollTimer?.invalidate()
        menuTrackingPollTimer = nil
    }

    private func installHoverMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if hoverLocalMouseMonitor == nil {
            hoverLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
                return event
            }
        }
        if hoverGlobalMouseMonitor == nil {
            hoverGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
            }
        }
    }

    private func hoverPollEventArrived() {
        guard Self.hoverMonitorLeanEnabled else {
            Task { @MainActor [weak self] in self?.pollAllUnits() }
            return
        }
        switch hoverPollThrottle.eventArrived(now: CACurrentMediaTime()) {
        case .run:
            pollAllUnits()
        case .scheduleTrailing(let after):
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverPollThrottle.trailingFired(now: CACurrentMediaTime())
                    self.pollAllUnits()
                }
            }
        case .drop:
            break
        }
    }

    private func pollAllUnits() {
        units.forEach { $0.coordinator.pollMousePosition() }
    }

    private func removeHoverMouseMonitorsOnly() {
        if let monitor = hoverLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMouseMonitor = nil
        }
        if let monitor = hoverGlobalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMouseMonitor = nil
        }
    }

    private func removeHoverMouseMonitors() {
        removeHoverMouseMonitorsOnly()
        hoverPollThrottle.reset()
        for unit in units {
            unit.coordinator.cancelHoverSwitch()
            unit.coordinator.cancelEdgeWake()
        }
    }
}
