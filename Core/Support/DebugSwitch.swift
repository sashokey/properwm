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
    case fullscreenSlsVerdict = "DOCK_FULLSCREEN_SLS_VERDICT"
    case overlayWindowWatch = "DOCK_OVERLAY_WINDOW_WATCH"
    case spaceMembershipRepair = "DOCK_SPACE_MEMBERSHIP_REPAIR"
    case overlaySpace = "DOCK_OVERLAY_SPACE"
    case windowLift = "DOCK_WINDOW_LIFT"
    case windowLiftAnim = "DOCK_WINDOW_LIFT_ANIM"
    case windowLiftTiles = "DOCK_WINDOW_LIFT_TILES"
    case titleSettle = "DOCK_TITLE_SETTLE"
    case displayTrace = "DOCK_DISPLAY_TRACE"
    case chipProbe = "DOCK_CHIP_PROBE"
    case clickTrace = "DOCK_CLICK_TRACE"
    case hoverTrace = "DOCK_HOVER_TRACE"
    case labelProbe = "DOCK_LABEL_PROBE"
    case windowLiftTrace = "DOCK_WINDOW_LIFT_TRACE"
    case simulateNoDestroy = "DOCK_SIMULATE_NO_DESTROY"
    case reconcileAxTimeoutMs = "DOCK_RECONCILE_AX_TIMEOUT_MS"
    case seedAxTimeoutMs = "DOCK_SEED_AX_TIMEOUT_MS"
    case inventoryLog = "DOCK_INVENTORY_LOG"
    case panelLevel = "DOCK_PANEL_LEVEL"

    var kind: Kind {
        switch self {
        case .eventAxAsync, .reconcileSkip, .scanGate, .frontmostCache, .cgSnapshotReuse, .axElementCache, .absentSeatRelease, .skylightFocus, .fastWindowHandle, .minimizeSettleGate, .handoffActiveGrace, .handoffActivePrediction, .staleActiveGuard, .fullscreenSlsVerdict, .overlayWindowWatch, .spaceMembershipRepair, .overlaySpace, .windowLift, .windowLiftAnim, .windowLiftTiles, .titleSettle:
            return .killSwitch
        case .displayTrace, .chipProbe, .clickTrace, .hoverTrace, .labelProbe, .windowLiftTrace, .simulateNoDestroy:
            return .trace
        case .reconcileAxTimeoutMs, .seedAxTimeoutMs, .inventoryLog, .panelLevel:
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
