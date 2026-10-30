import Foundation

enum DebugSwitch: String, CaseIterable, Sendable {
    enum Kind: Sendable { case killSwitch, trace, value }

    case eventAxAsync = "DOCK_EVENT_AX_ASYNC"
    case reconcileSkip = "DOCK_RECONCILE_SKIP"
    case scanGate = "DOCK_SCAN_GATE"
    case frontmostCache = "DOCK_FRONTMOST_CACHE"
    case cgSnapshotReuse = "DOCK_CG_SNAPSHOT_REUSE"
    case axElementCache = "DOCK_AX_ELEMENT_CACHE"
    case absentSeatRelease = "DOCK_ABSENT_SEAT_RELEASE"
    case skylightFocus = "DOCK_SKYLIGHT_FOCUS"
    case fastWindowHandle = "DOCK_FAST_WINDOW_HANDLE"
    case minimizeSettleGate = "DOCK_MINIMIZE_SETTLE_GATE"
    case handoffActiveGrace = "DOCK_HANDOFF_ACTIVE_GRACE"
    case handoffActivePrediction = "DOCK_HANDOFF_ACTIVE_PREDICTION"
    case staleActiveGuard = "DOCK_STALE_ACTIVE_GUARD"
    case dragLanding = "DOCK_DRAG_LANDING"
    case liquidGlass = "DOCK_LIQUID_GLASS"
    case liquidGlassDockRefraction = "DOCK_LIQUID_GLASS_DOCK_REFRACTION"
    case liquidGlassDiagonalHighlight = "DOCK_LIQUID_GLASS_DIAGONAL_HIGHLIGHT"
    case liquidGlassHighlightBoost = "DOCK_LIQUID_GLASS_HIGHLIGHT_BOOST"
    case stripBalancedInsets = "DOCK_STRIP_BALANCED_INSETS"
    case spaceIntent = "DOCK_SPACE_INTENT"
    case fullscreenIntent = "DOCK_FULLSCREEN_INTENT"
    case fullscreenSlsVerdict = "DOCK_FULLSCREEN_SLS_VERDICT"
    case overlayWindowWatch = "DOCK_OVERLAY_WINDOW_WATCH"
    case spaceMembershipRepair = "DOCK_SPACE_MEMBERSHIP_REPAIR"
    case overlaySpace = "DOCK_OVERLAY_SPACE"
    case windowLift = "DOCK_WINDOW_LIFT"
    case windowLiftAnim = "DOCK_WINDOW_LIFT_ANIM"
    case windowLiftTiles = "DOCK_WINDOW_LIFT_TILES"
    case menuHoverSuspend = "DOCK_MENU_HOVER_SUSPEND"
    case hoverMonitorLean = "DOCK_HOVER_MONITOR_LEAN"
    case stripHoverPoll = "DOCK_STRIP_HOVER_POLL"
    case resizeCursor = "DOCK_RESIZE_CURSOR"
    case barArrowCursor = "DOCK_BAR_ARROW_CURSOR"
    case chipPressDown = "DOCK_CHIP_PRESS_DOWN"
    case titleSettle = "DOCK_TITLE_SETTLE"
    case finderReopenEvent = "DOCK_FINDER_REOPEN_EVENT"

    case displayTrace = "DOCK_DISPLAY_TRACE"
    case chipProbe = "DOCK_CHIP_PROBE"
    case clickTrace = "DOCK_CLICK_TRACE"
    case hoverTrace = "DOCK_HOVER_TRACE"
    case edgehoverTrace = "DOCK_EDGEHOVER_TRACE"
    case stripWheelTrace = "DOCK_STRIP_WHEEL_TRACE"
    case chipAnimTrace = "DOCK_CHIP_ANIM_TRACE"
    case labelProbe = "DOCK_LABEL_PROBE"
    case spaceIntentTrace = "DOCK_SPACE_INTENT_TRACE"
    case windowLiftTrace = "DOCK_WINDOW_LIFT_TRACE"
    case minimizeAppFallback = "DOCK_MINIMIZE_APP_FALLBACK"
    case simulateNoDestroy = "DOCK_SIMULATE_NO_DESTROY"

    case reconcileAxTimeoutMs = "DOCK_RECONCILE_AX_TIMEOUT_MS"
    case seedAxTimeoutMs = "DOCK_SEED_AX_TIMEOUT_MS"
    case dragFlightMs = "DOCK_DRAG_FLIGHT_MS"
    case labelAnim = "DOCK_LABEL_ANIM"
    case inventoryLog = "DOCK_INVENTORY_LOG"
    case panelLevel = "DOCK_PANEL_LEVEL"
    case panelMaterial = "DOCK_PANEL_MATERIAL"
    case panelSaturation = "DOCK_PANEL_SATURATION"
    case panelThickness = "DOCK_PANEL_THICKNESS"
    case chipPillFill = "DOCK_CHIP_PILL_FILL"
    case labelInactive = "DOCK_LABEL_INACTIVE"
    case shelfTile = "DOCK_SHELF_TILE"
    case liquidGlassClearTint = "DOCK_LIQUID_GLASS_CLEAR_TINT"
    case liquidGlassWhiteOverlay = "DOCK_LIQUID_GLASS_WHITE_OVERLAY"
    case liquidGlassDimming = "DOCK_LIQUID_GLASS_DIMMING"
    case liquidGlassBorder = "DOCK_LIQUID_GLASS_BORDER"
    case liquidGlassBorderEdge = "DOCK_LIQUID_GLASS_BORDER_EDGE"
    case liquidGlassBorderCut = "DOCK_LIQUID_GLASS_BORDER_CUT"
    case liquidGlassBorderSpread = "DOCK_LIQUID_GLASS_BORDER_SPREAD"
    case liquidGlassBorderWidth = "DOCK_LIQUID_GLASS_BORDER_WIDTH"
    case liquidGlassBorderInner = "DOCK_LIQUID_GLASS_BORDER_INNER"
    case liquidGlassBackgroundOpacity = "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY"
    case liquidGlassWindowBlur = "DOCK_LIQUID_GLASS_WINDOW_BLUR"
    case liquidGlassContentInset = "DOCK_LIQUID_GLASS_CONTENT_INSET"
    case liquidGlassSystemVariant = "DOCK_LIQUID_GLASS_SYSTEM_VARIANT"

    var kind: Kind {
        switch self {
        case .eventAxAsync, .reconcileSkip, .scanGate, .frontmostCache,
             .cgSnapshotReuse, .axElementCache, .absentSeatRelease, .skylightFocus, .fastWindowHandle,
             .minimizeSettleGate, .handoffActiveGrace,
             .handoffActivePrediction, .staleActiveGuard, .dragLanding, .liquidGlass, .liquidGlassDockRefraction,
             .liquidGlassDiagonalHighlight, .liquidGlassHighlightBoost, .stripBalancedInsets,
             .spaceIntent, .fullscreenIntent, .fullscreenSlsVerdict, .overlayWindowWatch, .spaceMembershipRepair,
             .overlaySpace, .windowLift, .windowLiftAnim, .windowLiftTiles,
             .menuHoverSuspend, .hoverMonitorLean, .stripHoverPoll, .resizeCursor, .barArrowCursor, .chipPressDown, .titleSettle,
             .finderReopenEvent:
            return .killSwitch
        case .displayTrace, .chipProbe, .clickTrace,
             .hoverTrace, .edgehoverTrace, .stripWheelTrace, .chipAnimTrace, .labelProbe,
             .spaceIntentTrace, .windowLiftTrace, .minimizeAppFallback,
             .simulateNoDestroy:
            return .trace
        case .reconcileAxTimeoutMs, .seedAxTimeoutMs, .dragFlightMs, .labelAnim, .inventoryLog,
             .panelLevel, .panelMaterial, .panelSaturation, .panelThickness,
             .chipPillFill, .labelInactive, .shelfTile, .liquidGlassClearTint,
             .liquidGlassWhiteOverlay, .liquidGlassDimming, .liquidGlassBorder, .liquidGlassBorderEdge,
             .liquidGlassBorderCut, .liquidGlassBorderSpread, .liquidGlassBorderWidth, .liquidGlassBorderInner,
             .liquidGlassBackgroundOpacity, .liquidGlassWindowBlur, .liquidGlassContentInset,
             .liquidGlassSystemVariant:
            return .value
        }
    }

    func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[rawValue]
    }

    func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch kind {
        case .killSwitch: return environment[rawValue] != "0"
        case .trace: return environment[rawValue] == "1"
        case .value:
            assertionFailure("\(rawValue) is a value switch; read it with value(in:)")
            return environment[rawValue] != nil
        }
    }
}
