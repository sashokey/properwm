import AppKit
import Combine
import os

@MainActor
final class PanelCoordinator: NSObject {
    var panelHeight: CGFloat { TaskbarMetrics.height }
    static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }
    let runtime: AppRuntime
    let stripOrderStore: StripOrderStore
    let settingsStore: AppSettingsStore
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockContentHost: ManualPanelHost?
    var taskbarView: TaskbarView?
    var taskbarPresenter: TaskbarPresenter?
    var isSuspendedForPermissionLoss = false
    var displayTopologySubscription: AnyCancellable?
    let logger = Logger(subsystem: "io.github.sashokey.properwm", category: "dock-panel")
    let fullscreenIntentLogger = Logger(
        subsystem: "io.github.sashokey.properwm",
        category: "FullscreenIntent"
    )
    var fullscreenReconcileTimer: Timer?
    var workspaceObserverTokens: [NSObjectProtocol] = []
    var fullscreenIntentRoutingEnabled = false
    var fullscreenIntentTimeoutTimer: Timer?
    var fullscreenIntentGeneration: UInt64 = 0
    var fullscreenIntentTransaction: FullscreenIntentTransaction?
    var fullscreenProbeGeneration: UInt64 = 0
    var fullscreenSpaceHoldGeneration: UInt64 = 0
    var fullscreenSpaceHold: FullscreenSpaceHold?
    var fullscreenSpaceHoldTimer: Timer?
    static let overlayWindowWatchEnabled =
        DebugSwitch.overlayWindowWatch.isEnabled(in: ProcessInfo.processInfo.environment)
    var overlayWindowWatchTimer: Timer?
    var overlayWindowWatchID: CGWindowID?
    var fullscreenSpaceIntentGeneration: UInt64?
    var fullscreenSpaceIntentTimer: Timer?
    var fullscreenSpaceIntentVerdictTimer: Timer?
    var lastHideWasForFullscreen = false
    static let spaceMembershipRepairEnabled =
        DebugSwitch.spaceMembershipRepair.isEnabled(in: ProcessInfo.processInfo.environment)
    var spaceMembershipRepairInFlight = false
    var lastActiveApplicationPID: pid_t?
    var visibilityState = PanelVisibilityState()
    var isTaskbarMenuOpen = false
    var panelsAreVisible = true
    var diagnosticFullscreenSource = "not recorded"
    var diagnosticFullscreenVerdict: Bool?
    var onPanelScreenChanged: (() -> Void)?
    var onAccessoryWillOpen: ((PanelCoordinator, AccessoryKind) -> Void)?

    enum AccessoryKind { case popup }


    let unitPlacement: TaskbarUnitPlacement
    let overlaySpaceHost: OverlaySpaceHost?
    let stripSurfaceID = "strip-" + UUID().uuidString
    let displayTopologyStore: DisplayTopologyStore
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         overlaySpaceHost: OverlaySpaceHost?,
         runtime: AppRuntime,
         stripOrderStore: StripOrderStore,
         settingsStore: AppSettingsStore,
         displayTopologyStore: DisplayTopologyStore) {
        self.unitPlacement = placement
        self.overlaySpaceHost = overlaySpaceHost
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.settingsStore = settingsStore
        self.displayTopologyStore = displayTopologyStore
        super.init()
    }

    func start() {
        setupDockPanel()
        presentInitialPanels()
        pinResidentPanelsIfNeeded()
        subscribeSettings()
        setupFullscreenMonitor()
    }

    isolated deinit {
        fullscreenReconcileTimer?.invalidate()
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenSpaceHoldTimer?.invalidate()
        overlayWindowWatchTimer?.invalidate()
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        taskbarView?.taskbarContent.prepareForHiding()
        workspaceObserverTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func tearDown() {
        DiagnosticVisibilityRecorder.shared.history.remove(unit: stripSurfaceID)
        StripProjectionRegistry.shared.remove(surface: stripSurfaceID)
        guard !isSuspendedForPermissionLoss else { return }
        isSuspendedForPermissionLoss = true
        fullscreenIntentRoutingEnabled = false
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "teardown")
        }
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
        endOverlayWindowWatch()
        clearFullscreenSpaceArrowIntent()
        taskbarView?.taskbarContent.prepareForHiding()
        taskbarPresenter = nil
        dockContentHost = nil
        taskbarView = nil
        dockPanel?.contentView = NSView()
        dockPanel?.orderOut(nil)
        dockPanel?.close()
        dockPanel = nil
    }

    func dismissTaskbarPopups() {
        taskbarView?.taskbarContent.dismissPopups()
    }

    var currentScreen: NSScreen? { dockPanel.map { panelCurrentScreen(panel: $0) } }
    var isLogicallyVisible: Bool { panelsAreVisible }
    func windowLiftAvoidanceContext() -> WindowLiftAvoidanceContext? {
        guard visibilityState.isVisible,
              panelsAreVisible,
              let panel = dockPanel else {
            return nil
        }

        let screen = panelCurrentScreen(panel: panel)
        let primaryScreenHeight = Self.quartzPrimaryScreenHeight
        let geometry = WindowLiftAvoidance.Geometry(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            taskbarTop: screen.frame.minY + TaskbarMetrics.height
        )
        return WindowLiftAvoidanceContext(
            geometry: geometry,
            screenCGFrame: Self.toCGRect(screen),
            visibleCGFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: screen.visibleFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            primaryScreenHeight: primaryScreenHeight
        )
    }


    var allSpacesPanels: [NSPanel] { [dockPanel].compactMap { $0 } }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        let visualCenter = CGPoint(x: panel.frame.midX, y: panel.frame.minY + panelHeight / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(visualCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func toCGRect(_ screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.minX, y: quartzPrimaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static var quartzPrimaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    static let slsVerdictEnabled = DebugSwitch.fullscreenSlsVerdict.isEnabled(in: ProcessInfo.processInfo.environment)

    var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .primary: return nil
        }
    }
}
