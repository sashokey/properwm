import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

enum PanelAnimation {
    static let duration: TimeInterval = 0.22
}

@MainActor
final class PanelCoordinator: NSObject {
    var layoutMetrics: PanelLayoutMetrics { settingsStore.dockPanelHeight.metrics }
    var panelHeight: CGFloat { layoutMetrics.panelHeight }
    var windowHeight: CGFloat { layoutMetrics.windowHeight }
    var usesLiquidGlass: Bool { dockGlassBackgroundPanel != nil }

    static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }

    var taskbarPlateCornerRadius: CGFloat {
        DockShape.panelCornerRadius * settingsStore.dockPanelHeight.scale
    }
    static let shadowPadding: CGFloat = PanelLayoutMetrics.shadowPadding

    let runtime: AppRuntime
    let stripOrderStore: StripOrderStore
    let settingsStore: AppSettingsStore
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockGlassBackgroundPanel: NonConstrainingPanel?
    var dockGlassBackgroundView: DockTaskbarLiquidGlassBackgroundView?
    var dockContentHost: ManualPanelHost?
    let dragController: DragController
    var isSuspendedForPermissionLoss = false
    var windowTitleTooltipPanel: NSPanel?
    var windowTitleTooltipRequest: WindowTitleTooltipRequest?
    var windowTitleTooltipSuppressedChipID: String?
    var windowTitleTooltipSuppressedRequest: WindowTitleTooltipRequest?
    var windowTitleTooltipLingerTimer: Timer?
    var windowTitleTooltipWatchdog: Timer?
    var windowTitleTooltipLocalMonitor: Any?
    var windowTitleTooltipGlobalMonitor: Any?
    var windowTitleTooltipHosting: NSHostingView<WindowTitleTooltipView>?
    var windowTitleTooltipHost: ManualPanelHost?
    var snapshotWidthSubscription: AnyCancellable?
    var displayTopologySubscription: AnyCancellable?
    var dockPanelHeightSubscription: AnyCancellable?
    var panelHeightChangeGeneration: UInt64 = 0
    var interactiveResize: DockHeightDragSession?
    var interactiveHeightResizeActive = false
    let heightResizePresentation = PanelHeightResizePresentation()
    var liftContextPanelHeightOverride: CGFloat?
    var onInteractiveHeightResizeSession: ((Bool) -> Void)?
    var onInteractiveHeightResizeUpdate: (() -> Void)?
    let resizeGripController = StripResizeGripController()
    var resizeCursorPanel: NSPanel?
    var resizeCursorHost: ManualPanelHost?
    var gripHoverPointer: CGPoint?
    var resizeCursorReassertTimer: Timer?
    var lastDesiredWidth: CGFloat = 0
    var labelFollowTimer: Timer?
    var labelFollowRestWidth: CGFloat = 0
    var labelBoxStart: [String: CGFloat] = [:]
    var labelBoxLive: [String: CGFloat] = [:]
    var labelFollowDeadline: CFTimeInterval = 0
    var lastSnapshotWindowIDs: Set<WindowID>?
    var animatedFramesUntil: CFTimeInterval = 0
    var lastCommittedFrames: [NSRect] = []
    var lastDockTargetFrame: NSRect = .zero
    var didInitialLayout = false
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
    var panelsAreVisible = true
    var diagnosticFullscreenSource = "not recorded"
    var diagnosticFullscreenVerdict: Bool?
    var edgeIdleHideTimer: Timer?
    var edgeWakeTimer: Timer?
    var edgeWakeTargetScreen: NSScreen?
    var edgeWakeRequiresHotZone = true
    var onHoverMonitorsNeedReconcile: (() -> Void)?
    var onPanelScreenChanged: (() -> Void)?
    var onAccessoryWillOpen: ((PanelCoordinator, AccessoryKind) -> Void)?

    enum AccessoryKind { case tooltip }

    let unitPlacement: TaskbarUnitPlacement
    let overlaySpaceHost: OverlaySpaceHost?
    let stripSurfaceID = "strip-" + UUID().uuidString
    let displayTopologyStore: DisplayTopologyStore
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         dragController: DragController,
         overlaySpaceHost: OverlaySpaceHost?,
         runtime: AppRuntime,
         stripOrderStore: StripOrderStore,
         settingsStore: AppSettingsStore,
         displayTopologyStore: DisplayTopologyStore) {
        self.unitPlacement = placement
        self.dragController = dragController
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
        subscribeSnapshotWidth()
        subscribeSettings()
        setupFullscreenMonitor()
        if Self.hoverVerboseLogging { logScreenMap() }
    }

    deinit {
        fullscreenReconcileTimer?.invalidate()
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenSpaceHoldTimer?.invalidate()
        overlayWindowWatchTimer?.invalidate()
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        MainActor.assumeIsolated {
            dismissWindowTitleTooltip()
            tearDownTaskbarGlassBackground()
        }
        hoverSwitchTimer?.invalidate()
        edgeIdleHideTimer?.invalidate()
        edgeWakeTimer?.invalidate()
        workspaceObserverTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func tearDown() {
        DiagnosticVisibilityRecorder.shared.history.remove(unit: stripSurfaceID)
        StripProjectionRegistry.shared.remove(surface: stripSurfaceID)
        guard !isSuspendedForPermissionLoss else { return }
        isSuspendedForPermissionLoss = true
        cancelInteractiveResize()
        tearDownResizeCursor()
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

        dismissWindowTitleTooltip()
        cancelHoverSwitch()
        cancelEdgeWake()
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        dockContentHost = nil
        windowTitleTooltipHosting = nil
        windowTitleTooltipHost = nil
        tearDownTaskbarGlassBackground()
        for panel in [dockPanel, windowTitleTooltipPanel] {
            guard let panel else { continue }
            panel.contentView = NSView()
            panel.orderOut(nil)
            panel.close()
        }
        dockPanel = nil
        windowTitleTooltipPanel = nil
        lastCommittedFrames = []
    }

    var currentScreen: NSScreen? {
        dockPanel.map { panelCurrentScreen(panel: $0) }
    }

    var isLogicallyVisible: Bool { panelsAreVisible }

    func windowLiftAvoidanceContext() -> WindowLiftAvoidanceContext? {
        guard !settingsStore.edgeAutoHideEnabled,
              visibilityState.isVisible,
              panelsAreVisible,
              let panel = dockPanel else {
            return nil
        }

        let screen = panelCurrentScreen(panel: panel)
        let primaryScreenHeight = Self.quartzPrimaryScreenHeight
        let geometry = WindowLiftAvoidance.Geometry(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            taskbarTop: screen.frame.minY
                + layoutMetrics.bottomGap
                + (liftContextPanelHeightOverride ?? layoutMetrics.panelHeight)
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

    static let windowTitleTooltipLingerDelay: TimeInterval = 0.09

    static let layoutAnimationDuration: TimeInterval = PanelAnimation.duration

    var allSpacesPanels: [NSPanel] {
        [dockGlassBackgroundPanel, dockPanel].compactMap { $0 }
    }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        let visualCenter = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + Self.shadowPadding + panelHeight / 2
        )
        return NSScreen.screens.first(where: { $0.frame.contains(visualCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func toCGRect(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: f.minX,
            y: quartzPrimaryScreenHeight - f.maxY,
            width: f.width,
            height: f.height
        )
    }

    private static var quartzPrimaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    static let slsVerdictEnabled = DebugSwitch.fullscreenSlsVerdict.isEnabled(in: ProcessInfo.processInfo.environment)

    let hoverLogger = Logger(subsystem: "io.github.sashokey.properwm", category: "HoverSwitch")
    static let hoverHotZone: CGFloat = 4.0
    static let hoverSwitchDwell: TimeInterval = 0.35   // 光标驻留热区 ≥ 350ms 才切换，路过不算
    static let hoverVerboseLogging = false
    static let edgeHoverTraceEnabled = DebugSwitch.edgehoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    var hoverLastScreenIndex: Int? = nil
    var hoverLastInHotZone: Bool? = nil
    var hoverSwitchTimer: Timer?
    var hoverSwitchTargetScreen: NSScreen? = nil

    var hoverScreenSwitchingEnabled: Bool {
        switch unitPlacement {
        case .followSettings: return settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching
        case .fixed: return false
        }
    }

    var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .followSettings: return settingsStore.taskbarScreenPlacement.pinnedSelection?.uuid
        }
    }

    private static let outerMargin: CGFloat = PanelLayoutMetrics.properWM.outerMargin

}
