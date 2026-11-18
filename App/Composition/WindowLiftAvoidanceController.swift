import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
#if DEBUG
import os
#endif

private let windowLiftAXMessagingTimeout: TimeInterval = 0.1

struct WindowLiftCGCandidate: Equatable, Sendable {
    let key: WindowLiftAvoidance.WindowKey
    let quartzFrame: CGRect
}

struct WindowLiftCGScanResult: Sendable {
    /// 每块屏（按传入的 `screenCGFrames` 下标）各自的前台大窗候选；没有的屏不在字典里。
    let candidatesByScreenIndex: [Int: WindowLiftCGCandidate]
    let onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect]
    let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
}

/// 避让宿主：给出「哪些屏有一条常驻且可见的任务条」的几何，每屏一份（③④ 下由编排层汇总各单元）。
@MainActor
protocol WindowLiftAvoidanceHost: AnyObject {
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext]
    func windowGeometryChanged()
}

enum WindowLiftCGWindowProbe {
    static func capture(
        on contexts: [WindowLiftAvoidanceContext],
        excludingPID selfPID: pid_t,
        includeLiveWindowKeys: Bool,
        includesTiles: Bool,
        trackedKeys: Set<WindowLiftAvoidance.WindowKey>,
        livenessKeys: Set<WindowLiftAvoidance.WindowKey>? = nil,
        system: any WindowSystemAccess = NativeWindowSystem()
    ) -> WindowLiftCGScanResult {
        let onScreenCapture = system.windowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        var onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        var onScreenKeys: Set<WindowLiftAvoidance.WindowKey> = []
        var candidates: [Int: WindowLiftCGCandidate] = [:]

        for info in onScreenCapture ?? [] {
            guard let key = windowKey(in: info) else { continue }
            if includeLiveWindowKeys { onScreenKeys.insert(key) }
            guard let quartzFrame = windowBounds(in: info) else { continue }
            onScreenFrames[key] = quartzFrame

            guard candidates.count < contexts.count,
                  key.pid != selfPID, quartzFrame.width >= 80, quartzFrame.height >= 40,
                  isVisibleAtNormalLayer(info) else { continue }
            let candidate = WindowLiftCGCandidate(key: key, quartzFrame: quartzFrame)
            let isTracked = trackedKeys.contains(key)
            for (index, context) in contexts.enumerated() where candidates[index] == nil {
                if quartzFrame.intersects(context.screenCGFrame), WindowLiftAvoidance.isLiftCandidate(
                    quartzFrame: quartzFrame, isTracked: isTracked, context: context, includesTiles: includesTiles
                ) {
                    candidates[index] = candidate
                }
            }
        }

        let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
        if !includeLiveWindowKeys {
            liveWindowKeys = nil
        } else if onScreenCapture != nil, (livenessKeys ?? trackedKeys).isSubset(of: onScreenKeys) {
            liveWindowKeys = onScreenKeys
        } else {
            liveWindowKeys = allWindowKeys(using: system)
        }

        return WindowLiftCGScanResult(
            candidatesByScreenIndex: candidates,
            onScreenFrames: onScreenFrames,
            liveWindowKeys: liveWindowKeys
        )
    }

    static func liveWindowKeys() -> Set<WindowLiftAvoidance.WindowKey>? {
        allWindowKeys(using: NativeWindowSystem())
    }

    private static func allWindowKeys(using system: any WindowSystemAccess) -> Set<WindowLiftAvoidance.WindowKey>? {
        system.windowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            .map { Set($0.compactMap(windowKey(in:))) }
    }

    static func frames(
        for keys: Set<WindowLiftAvoidance.WindowKey>,
        system: any WindowSystemAccess = NativeWindowSystem()
    ) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        guard !keys.isEmpty,
              let list = system.windowDescriptions(for: Array(Set(keys.map(\.cgWindowID)))) else { return [:] }

        var frames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for info in list {
            guard let key = windowKey(in: info), keys.contains(key),
                  let bounds = windowBounds(in: info) else {
                continue
            }
            frames[key] = bounds
        }
        return frames
    }

    static func frontmostLargeWindow(
        in list: [[String: Any]],
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        for info in list {
            guard isVisibleAtNormalLayer(info),
                  let key = windowKey(in: info),
                  key.pid != selfPID,
                  let bounds = windowBounds(in: info),
                  bounds.intersects(screenCGFrame),
                  bounds.width > screenCGFrame.width * 0.7,
                  bounds.width >= 80,
                  bounds.height >= 40 else {
                continue
            }
            return WindowLiftCGCandidate(key: key, quartzFrame: bounds)
        }
        return nil
    }

    private static func isVisibleAtNormalLayer(_ info: [String: Any]) -> Bool {
        number(in: info, key: kCGWindowLayer)?.intValue == 0
            && (number(in: info, key: kCGWindowAlpha)?.doubleValue ?? 1) > 0
    }

    private static func windowKey(in info: [String: Any]) -> WindowLiftAvoidance.WindowKey? {
        guard let pid = number(in: info, key: kCGWindowOwnerPID)?.int32Value,
              let windowID = number(in: info, key: kCGWindowNumber)?.uint32Value,
              windowID != 0 else {
            return nil
        }
        return WindowLiftAvoidance.WindowKey(pid: pid, cgWindowID: windowID)
    }

    private static func windowBounds(in info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func number(in info: [String: Any], key: CFString) -> NSNumber? {
        info[key as String] as? NSNumber
    }
}

protocol WindowLiftWindowProbing: Sendable {
    func capture(on contexts: [WindowLiftAvoidanceContext], excludingPID: pid_t,
                 includeLiveWindowKeys: Bool, includesTiles: Bool,
                 trackedKeys: Set<WindowLiftAvoidance.WindowKey>,
                 livenessKeys: Set<WindowLiftAvoidance.WindowKey>) -> WindowLiftCGScanResult
    func frames(for keys: Set<WindowLiftAvoidance.WindowKey>) -> [WindowLiftAvoidance.WindowKey: CGRect]
}

struct LiveWindowLiftProbe: WindowLiftWindowProbing {
    var system: any WindowSystemAccess = NativeWindowSystem()
    func capture(on contexts: [WindowLiftAvoidanceContext], excludingPID: pid_t,
                 includeLiveWindowKeys: Bool, includesTiles: Bool,
                 trackedKeys: Set<WindowLiftAvoidance.WindowKey>,
                 livenessKeys: Set<WindowLiftAvoidance.WindowKey>) -> WindowLiftCGScanResult {
        WindowLiftCGWindowProbe.capture(on: contexts, excludingPID: excludingPID,
            includeLiveWindowKeys: includeLiveWindowKeys, includesTiles: includesTiles, trackedKeys: trackedKeys, livenessKeys: livenessKeys, system: system)
    }

    func frames(for keys: Set<WindowLiftAvoidance.WindowKey>) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        WindowLiftCGWindowProbe.frames(for: keys, system: system)
    }
}

@MainActor
final class WindowLiftAvoidanceController {
    typealias ManagedFrames = WindowRestorationFrames

    private enum ValidationStage: String {
        case candidateMoved
        case processIdentityUnavailable
        case handleUnavailable
        case roleUnavailable
        case unsupportedRole
        case fullscreen
        case minimized
        case frameUnavailable
        case frameMismatch
        case capabilityUnavailable
        case sizeNotSettable
    }

    private struct ValidationFrames {
        #if DEBUG
        let cg: CGRect
        let ax: CGRect?
        #else
        @inline(__always)
        init(cg: CGRect, ax: CGRect?) {}
        #endif
    }

    private struct WriteWindowIdentity: Sendable {
        let key: WindowLiftAvoidance.WindowKey
        let generation: ProcessGeneration
        let system: any WindowSystemAccess

        var processMatches: Bool { system.generation(key.pid) == generation }
    }

    private enum ValidationOutcome {
        case ready(AXWindowHandle)
        case transient(ValidationStage, ValidationFrames? = nil)
        case unsupported(ValidationStage)
    }

    private struct WriteAnomaly {
        #if DEBUG
        let reason: AXWindowFrameWriteFailure
        let rollback: AXWindowFrameRollbackResult
        let decision: WindowLiftAvoidance.AnimationWriteFailureDecision
        let progress: Double
        #else
        @inline(__always)
        init(reason: AXWindowFrameWriteFailure, rollback: AXWindowFrameRollbackResult,
             decision: WindowLiftAvoidance.AnimationWriteFailureDecision, progress: Double) {}
        #endif
    }

    /// What `clearManagedSession` leaves behind for the window it clears.
    enum SuppressionRequest {
        case none
        /// Hold the window until its native frame reappears; `userEra` additionally lets a new
        /// eligible frame release it (`Geometry.suppressionReleasesOnNewFrame`).
        case untilNative(userEra: Bool)
        case afterAppAnswer
    }

    private enum OperationOutcome {
        case completed(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case externalFrame(CGRect, anomalies: [WriteAnomaly])
        case reliftLimitReached(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case failed(
            reason: AXWindowFrameWriteFailure,
            rollback: AXWindowFrameRollbackResult,
            progress: Double,
            reliftCount: Int,
            managedWriteFrames: WindowLiftWriteFrames,
            anomalies: [WriteAnomaly]
        )
        case transientValidation(ValidationStage, ValidationFrames? = nil)
        case unsupportedValidation(ValidationStage)
        case cancelled
        case cancelledWrite(AXWindowFrameRollbackResult, managedWriteFrames: WindowLiftWriteFrames)
    }

    nonisolated private static let geometryQueue = DispatchQueue(label: "io.github.sashokey.properwm.window-geometry", qos: .userInitiated)

    private static let trackedProbeInterval = WindowLiftAvoidance.trackedSessionProbeInterval

    private weak var host: WindowLiftAvoidanceHost?
    #if DEBUG
    private let logger = Logger(
        subsystem: "io.github.sashokey.properwm",
        category: "WindowLiftAvoidance"
    )
    #endif
    private var pollTimer: Timer?
    var pollTimerInterval: TimeInterval?
    private var eventPollTimer: Timer?
    private var eventPollCoalescer = WindowLiftAvoidance.EventPollCoalescer()
    var scanTask: Task<Void, Never>?
    var trackedProbeTimer: Timer?
    var trackedProbeTask: Task<Void, Never>?
    var restoreTask: Task<Void, Never>?
    var writeTasks: [WindowLiftAvoidance.WindowKey: Task<Void, Never>] = [:]
    var writeDrainTasks: [
        WindowLiftAvoidance.WindowKey: [UUID: Task<Void, Never>]
    ] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var geometryObserver: FrontmostWindowGeometryObserver?
    var states: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.SessionState] = [:]
    var managedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    private var suppressedFrames: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.Suppression] = [:]
    private var observationWatermarks: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private struct ConfirmedLift {
        let session: WindowLiftAvoidance.LiftedSession
        let frames: ManagedFrames
    }
    private struct PendingValidation {
        let generation: UInt64
        let confirmedLift: ConfirmedLift?
        var requiresActiveApplication: Bool { confirmedLift == nil }
    }
    private var pendingValidations: [WindowLiftAvoidance.WindowKey: PendingValidation] = [:]
    #if DEBUG
    private var lastTraceClassifications: [
        WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.FrameClassification
    ] = [:]
    private var reportedClearanceLosses: [
        WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.FrameClassification
    ] = [:]
    #endif
    private var lastContexts: [WindowLiftAvoidanceContext] = []
    /// 每个会话归属的那块屏的上下文（多屏下各会话不同屏）。随 `states` 增删，探测时按它分别处理。
    var sessionContexts: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidanceContext] = [:]
    private var nextGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var trackedProbeGeneration: UInt64 = 0
    private var restoreGeneration: UInt64 = 0
    private var scanInFlight = false
    private var usesAnimatedLift = false
    /// `DOCK_WINDOW_LIFT_TILES`: bottom-docked tiles lift too. Off = maximized windows only.
    private var includesTiles = false
    #if DEBUG
    private var traceEnabled = false
    private var periodicPollCount: UInt64 = 0
    private var eventPollCount: UInt64 = 0
    private var trailingEventPollCount: UInt64 = 0
    #endif
    var isEnabled = false

    /// 冻结期间：只丢任务引用，绝不动 `states` / `managedFrames` / `suppressedFrames` /
    /// `pendingRestorations`。撤权之后 AX 写不动窗口，这时候清掉快照等于永久丢失还原能力。
    private var isPermissionFrozen = false
    private var freezeGeneration: UInt64 = 0
    private var unfreezeGeneration: UInt64 = 0
    private var unfreezeTask: Task<Void, Never>?
    private var permissionDrainTask: Task<Void, Never>?
    /// 待还原窗口归控制器所有：还原成功一项才移除。以前这批数据是拷进局部变量
    /// 再交给 detached task 的，中途失权时新的冻结机制根本接管不到。
    var pendingRestorations: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    /// 入列时的进程启动时间，用来在长时间冻结后识别 pid 复用。
    /// 被取消但还没跑完的写任务。取消的 AX 调用没法半路打断，恢复前必须排空，
    /// 否则迟到的 rollback 会盖掉还原结果。
    private var pendingDrains: [Task<Void, Never>] = []
    private let isTrustedProbe: () -> Bool
    private let makeGeometryObserver: @MainActor () -> FrontmostWindowGeometryObserver
    private let reader: AXWindowReader
    private let system: any WindowSystemAccess
    private let windowProbe: any WindowLiftWindowProbing
    private let uptime: @Sendable () -> TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    #if DEBUG
    private let diagnosticReporter: ((String) -> Void)?
    #endif
    private var pendingRestorationDrains: [Task<Void, Never>] = []

    typealias RestoreWindow = @Sendable (WindowLiftAvoidance.WindowKey, WindowRestorationFrames, timeval?, Set<WindowLiftAvoidance.WindowKey>?, OperationReadBudget) -> WindowRestorationOutcome
    private let restoreWindow: RestoreWindow
    private let restorationWindowKeys: @Sendable () -> Set<WindowLiftAvoidance.WindowKey>?
    private var nextRestoreRetryAt: TimeInterval = 0
    private var lastRestorationAttemptKey: WindowLiftAvoidance.WindowKey?

    init(host: WindowLiftAvoidanceHost, isTrustedProbe: @escaping () -> Bool = { AXIsProcessTrusted() },
         restoreWindow: @escaping RestoreWindow = { key, frames, start, live, budget in
             WindowRestorer(access: AXWindowRestorationAccess(reader: AXWindowReader().withOperationBudget(budget)))
                 .restore(key: key, frames: frames, expectedStartTime: start, liveWindowKeys: live,
                          cancellation: budget.cancellation, budget: budget)
         },
         restorationWindowKeys: @escaping @Sendable () -> Set<WindowLiftAvoidance.WindowKey>? = WindowLiftCGWindowProbe.liveWindowKeys,
         windowProbe: any WindowLiftWindowProbing = LiveWindowLiftProbe(),
         reader: AXWindowReader = AXWindowReader(), system: any WindowSystemAccess = NativeWindowSystem(),
         makeGeometryObserver: @escaping @MainActor () -> FrontmostWindowGeometryObserver = { FrontmostWindowGeometryObserver() },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         diagnosticReporter: ((String) -> Void)? = nil) {
        self.host = host
        self.isTrustedProbe = isTrustedProbe
        self.restoreWindow = restoreWindow
        self.restorationWindowKeys = restorationWindowKeys
        self.makeGeometryObserver = makeGeometryObserver
        self.reader = reader
        self.system = system
        self.windowProbe = windowProbe
        self.uptime = uptime
        self.workspaceNotificationCenter = workspaceNotificationCenter
        #if DEBUG
        self.diagnosticReporter = diagnosticReporter
        #endif
    }

    // MARK: - 权限冻结

    /// 权限第一次读不到时调用。用户界面此刻还没有任何变化，但快照必须立刻锁住。
    func beginPermissionUncertainty() {
        enterFreeze(reason: "permissionUncertain")
    }

    /// 误报路径：权限又读到了。**分级解冻**——先排空旧 writer、提升代次拒绝迟到回调、
    /// 按当前情况收敛被冻结的会话，最后才恢复轮询。直接清冻结位会留下一个
    /// writer 已死、却永远不会重新发起写入的 `.writing` 会话（纯 reducer 对后续观察
    /// 只更新代次），那个窗口就再也不动了。
    func endPermissionUncertainty() {
        guard isPermissionFrozen, unfreezeTask == nil, isTrustedProbe() else { return }
        unfreezeGeneration &+= 1
        let generation = unfreezeGeneration

        unfreezeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.awaitPermissionDrains()
            guard self.unfreezeGeneration == generation else { return }
            self.unfreezeTask = nil
            guard !Task.isCancelled, self.isPermissionFrozen, self.isTrustedProbe() else { return }
            self.isPermissionFrozen = false
            self.convergeFrozenSessions()
            self.start()
        }
    }

    private func cancelPermissionUnfreeze() {
        unfreezeGeneration &+= 1
        unfreezeTask?.cancel()
        unfreezeTask = nil
    }

    private func awaitPermissionDrains() async {
        while true {
            if let task = permissionDrainTask {
                await task.value
                continue
            }
            guard !pendingDrains.isEmpty else { return }
            let drains = pendingDrains
            pendingDrains.removeAll()
            let task = Task { @MainActor [weak self] in
                for task in drains { await task.value }
                self?.permissionDrainTask = nil
                self?.releaseUnusedObservationWatermarks()
            }
            permissionDrainTask = task
            await task.value
        }
    }

    @discardableResult
    func restoreAndStopForPermissionRecovery() async -> WindowRestorationCompletion {
        await stopAndRestore()
    }

    private func enterFreeze(reason: String) {
        cancelPermissionUnfreeze()
        freezeGeneration &+= 1
        guard !isPermissionFrozen else { return }
        isPermissionFrozen = true
        // 已经排进主队列的 poll() 只看这个字段，必须一并关掉。
        isEnabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for task in writeTasks.values {
            task.cancel()
            pendingDrains.append(task)
        }
        for tasks in writeDrainTasks.values { pendingDrains.append(contentsOf: tasks.values) }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()
        pendingDrains.append(contentsOf: pendingRestorationDrains)
        pendingRestorationDrains.removeAll()
        restoreGeneration &+= 1
        if let restoreTask {
            restoreTask.cancel()
            pendingDrains.append(restoreTask)
            self.restoreTask = nil
        }

        #if DEBUG
        logger.notice("""
            lift frozen reason=\(reason, privacy: .public) \
            sessions=\(self.states.count, privacy: .public) \
            pending=\(self.pendingRestorations.count, privacy: .public)
            """)
        #endif
    }

    /// 解冻收敛：writer 已经被取消的 `.writing` 会话不可能自己走完，就地清掉。
    /// 用 `.untilNative` 清，免得下一轮把「已经被抬起的位置」当成原生位置再抬一次。
    private func convergeFrozenSessions() {
        let stalled = states.compactMap { key, state -> WindowLiftAvoidance.WindowKey? in
            if case .writing = state { return key }
            return nil
        }
        for key in stalled {
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "permissionUnfreeze",
                suppression: .untilNative(userEra: false)
            )
        }
    }

    /// 冻结期间禁止一切会抹掉会话数据的操作。
    private func canMutateSessions() -> Bool { !isPermissionFrozen }

    private func ensureTrustedOrFreeze() -> Bool {
        if isPermissionFrozen { return false }
        guard isTrustedProbe() else {
            enterFreeze(reason: "selfCheck")
            return false
        }
        return true
    }

    isolated deinit {
        stopMonitoring()
        unfreezeTask?.cancel()
        permissionDrainTask?.cancel()
        for task in pendingDrains { task.cancel() }
        for task in writeTasks.values { task.cancel() }
        for tasks in writeDrainTasks.values { for task in tasks.values { task.cancel() } }
        restoreTask?.cancel()
        for task in pendingRestorationDrains { task.cancel() }
    }

    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isEnabled, !isPermissionFrozen else { return }
        guard DebugSwitch.windowLift.isEnabled(in: environment) else {
            #if DEBUG
            logger.info("window lift disabled by DOCK_WINDOW_LIFT=0")
            #endif
            return
        }

        isEnabled = true
        usesAnimatedLift = DebugSwitch.windowLiftAnim.isEnabled(in: environment)
        includesTiles = DebugSwitch.windowLiftTiles.isEnabled(in: environment)
        #if DEBUG
        traceEnabled = DebugSwitch.windowLiftTrace.isEnabled(in: environment)
        periodicPollCount = 0
        eventPollCount = 0
        trailingEventPollCount = 0
        #endif
        subscribeWorkspaceNotifications()

        let geometryObserver = makeGeometryObserver()
        geometryObserver.onEvent = { [weak self] _ in
            self?.host?.windowGeometryChanged()
            self?.requestEventPoll()
        }
        self.geometryObserver = geometryObserver
        let initialPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?
            .processIdentifier
        geometryObserver.start(pid: initialPID)

        updatePollTimerLifecycle()
        poll()
        #if DEBUG
        if traceEnabled {
            logger.info("window lift trace started animated=\(self.usesAnimatedLift, privacy: .public) tiles=\(self.includesTiles, privacy: .public)")
        }
        #endif
    }

    func stop() {
        cancelPermissionUnfreeze()
        if !isPermissionFrozen, !isTrustedProbe() { enterFreeze(reason: "shutdown") }
        stopMonitoring()
        restoreSettledWindowsAndClearSessions()
        lastContexts = []
        sessionContexts.removeAll()
        releaseUnusedObservationWatermarks()
    }

    private func stopMonitoring() {
        #if DEBUG
        tracePollSummary(reason: "stop")
        #endif
        isEnabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    @discardableResult
    func stopAndRestore() async -> WindowRestorationCompletion {
        stop()
        let generation = freezeGeneration
        await awaitPermissionDrains()
        if isPermissionFrozen, freezeGeneration == generation, isTrustedProbe() {
            isPermissionFrozen = false
            stop()
        }
        while let task = restoreTask {
            await task.value
        }
        await awaitPermissionDrains()
        return restorationCompletion
    }

    private var restorationCompletion: WindowRestorationCompletion {
        let remaining = Set(pendingRestorations.keys).union(managedFrames.keys).count
        return remaining == 0 ? .complete : .incomplete(remaining: remaining)
    }

    private func subscribeWorkspaceNotifications() {
        let center = workspaceNotificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelUnstartedWrites(except: activePID)
                self.geometryObserver?.activate(pid: activePID)
                self.requestEventPoll()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                self.removeStates(forPID: pid)
            }
        })
    }

    private func hostContexts() -> [WindowLiftAvoidanceContext] {
        host?.windowLiftAvoidanceContexts() ?? []
    }

    func poll() {
        guard isEnabled, ensureTrustedOrFreeze() else { return }
        updatePollTimerLifecycle()
        updateTrackedProbeLifecycle()
        geometryObserver?.retryUnavailableObservation()
        if !pendingRestorations.isEmpty, restoreTask == nil,
           uptime() >= nextRestoreRetryAt {
            launchRestoreTask(cancelledWrites: [])
        }
        let contexts = hostContexts()
        reconcileContexts(contexts)
        guard !contexts.isEmpty, !scanInFlight, restoreTask == nil else { return }

        scanInFlight = true
        scanGeneration &+= 1
        let generation = scanGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        let tracked = !states.isEmpty || !suppressedFrames.isEmpty
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let includesTiles = includesTiles
        let trackedKeys = Set(states.keys)
        let livenessKeys = trackedKeys.union(suppressedFrames.keys)
        let probe = windowProbe
        scanTask = Task.detached { [weak self] in
            guard let result = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), operation: {
                probe.capture(on: contexts, excludingPID: selfPID, includeLiveWindowKeys: tracked,
                              includesTiles: includesTiles, trackedKeys: trackedKeys, livenessKeys: livenessKeys)
            }) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleScanResult(
                    result,
                    contexts: contexts,
                    scanGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    func updatePollTimerLifecycle() {
        guard isEnabled else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerInterval = nil
            return
        }

        let interval = WindowLiftAvoidance.PollCadence.interval(
            states: Array(states.values), suppressions: Array(suppressedFrames.values), at: uptime()
        )
        guard pollTimer == nil || pollTimerInterval != interval else { return }

        let previousInterval = pollTimerInterval
        #if DEBUG
        if traceEnabled, let previous = previousInterval {
            logger.info(
                "lift trace cadence from=\(previous, privacy: .public) to=\(interval, privacy: .public)"
            )
        }
        #endif
        pollTimer?.invalidate()
        resetEventPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                self.periodicPollCount &+= 1
                #endif
                self.poll()
            }
        }
        if interval == WindowLiftAvoidance.PollCadence.idleInterval { timer.tolerance = interval * 0.1 }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTimerInterval = interval

        if previousInterval == WindowLiftAvoidance.globalDetectionInterval,
           interval == WindowLiftAvoidance.PollCadence.idleInterval {
            Task { @MainActor [weak self] in self?.requestEventPoll() }
        }
    }

    private var usesFastPollCadence: Bool {
        pollTimerInterval == WindowLiftAvoidance.globalDetectionInterval
    }

    func requestEventPoll() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.request(
            at: uptime(),
            scanInFlight: scanInFlight
        )
        performEventPollAction(action, trailing: false)
    }

    private func finishEventPollAfterScan() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.scanCompleted(
            at: uptime()
        )
        performEventPollAction(action, trailing: true)
    }

    private func performEventPollAction(
        _ action: WindowLiftAvoidance.EventPollCoalescer.Action,
        trailing: Bool
    ) {
        switch action {
        case .none:
            break
        case .start:
            eventPollTimer?.invalidate()
            eventPollTimer = nil
            #if DEBUG
            if trailing {
                trailingEventPollCount &+= 1
            } else {
                eventPollCount &+= 1
            }
            #endif
            poll()
        case .schedule(let delay):
            guard eventPollTimer == nil else { return }
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.eventPollTimer = nil
                    let action = self.eventPollCoalescer.cooldownFired(
                        at: uptime(),
                        scanInFlight: self.scanInFlight
                    )
                    self.performEventPollAction(action, trailing: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            eventPollTimer = timer
        }
    }

    private func resetEventPolling() {
        eventPollTimer?.invalidate()
        eventPollTimer = nil
        eventPollCoalescer.reset()
    }

    #if DEBUG
    private func tracePollSummary(reason: String) {
        guard traceEnabled else { return }
        logger.info(
            "lift trace poll-summary reason=\(reason, privacy: .public) periodic=\(self.periodicPollCount, privacy: .public) event=\(self.eventPollCount, privacy: .public) trailing=\(self.trailingEventPollCount, privacy: .public)"
        )
    }
    #endif

    private var fastProbeKeys: Set<WindowLiftAvoidance.WindowKey> {
        let now = uptime()
        return Set(states.compactMap { WindowLiftAvoidance.PollCadence.needsFastProbe($0.value, at: now) ? $0.key : nil })
    }

    func updateTrackedProbeLifecycle() {
        guard isEnabled, !fastProbeKeys.isEmpty, restoreTask == nil else {
            stopTrackedProbe()
            return
        }
        guard trackedProbeTimer == nil else { return }

        let timer = Timer(timeInterval: Self.trackedProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probeTrackedFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackedProbeTimer = timer
    }

    private func stopTrackedProbe() {
        trackedProbeTimer?.invalidate()
        trackedProbeTimer = nil
        trackedProbeGeneration &+= 1
        trackedProbeTask?.cancel()
        trackedProbeTask = nil
    }

    func probeTrackedFrames() {
        guard isEnabled,
              restoreTask == nil,
              trackedProbeTask == nil,
              !lastContexts.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }
        let contexts = lastContexts
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }

        let keys = fastProbeKeys
        guard !keys.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }

        trackedProbeGeneration &+= 1
        let generation = trackedProbeGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        let probe = windowProbe
        trackedProbeTask = Task.detached { [weak self] in
            guard let frames = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), operation: { probe.frames(for: keys) }) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleTrackedProbeResult(
                    frames,
                    contexts: contexts,
                    probeGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func handleTrackedProbeResult(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        probeGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard probeGeneration == trackedProbeGeneration else { return }
        defer {
            trackedProbeTask = nil
            releaseUnusedObservationWatermarks()
        }
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }
        guard restoreTask == nil else { return }

        for (key, quartzFrame) in quartzFrames {
            guard let context = sessionContexts[key], contexts.contains(context) else { continue }
            _ = handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            )
        }
        updateTrackedProbeLifecycle()
    }

    @discardableResult
    private func handleTrackedObservation(
        _ quartzFrame: CGRect,
        for key: WindowLiftAvoidance.WindowKey,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard pendingRestorations[key] == nil else { return true }
        guard let state = states[key], let frames = managedFrames[key] else { return false }
        guard acceptObservation(for: key, generation: observationGeneration) else { return true }

        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let classification = WindowLiftAvoidance.frameClassification(
            of: appKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        )
        #if DEBUG
        traceClassification(classification, for: key)
        #endif

        if case let .writing(attempt) = state,
           pendingValidations[key]?.generation == attempt.generation,
           classification == .external {
            // The bounded CG/AX confirmation owns zoom-tail movement until it either stabilizes or
            // returns candidateMoved. No AX write has happened yet, so never suppress this frame.
            return true
        }

        let observedAt = uptime()
        var event = WindowLiftAvoidance.Event.nonMaximizedObserved(
            generation: observationGeneration,
            at: observedAt,
            frame: appKitFrame
        )
        var confirmedLift: ConfirmedLift?
        if case let .lifted(session) = state {
            let maximizedTarget = classification == .target ? nil : context.geometry.adjustedFrame(
                forMaximizedReturn: appKitFrame, from: frames.nativeAppKit
            )
            if classification == .native || maximizedTarget != nil {
                guard hostContexts().contains(context) else { return true }
                confirmedLift = ConfirmedLift(session: session, frames: frames)
            }
            if let maximizedTarget {
                event = .maximizedDetected(
                    generation: observationGeneration,
                    at: observedAt,
                    nativeFrame: appKitFrame,
                    targetFrame: maximizedTarget
                )
            }
        }

        let transition = WindowLiftAvoidance.reduce(state: state, event: event)
        #if DEBUG
        if case let .lifted(session) = state {
            let screen = context.geometry.screenFrame
            let panel = CGRect(x: screen.minX, y: screen.minY, width: screen.width,
                               height: context.geometry.taskbarTop - screen.minY)
            if appKitFrame.intersection(panel).isEmpty {
                reportedClearanceLosses.removeValue(forKey: key)
            } else if reportedClearanceLosses.updateValue(classification, forKey: key) != classification {
                let decision: String
                switch transition.action {
                case .none: decision = "none"
                case .clear: decision = "clear"
                case let .abandon(reason): decision = "abandon(\(reason.diagnosticDescription))"
                case let .write(_, _, _, isRelift): decision = isRelift ? "relift" : "write"
                }
                let age = max(0, observedAt - session.settledAt)
                reportDiagnostic("clearance lost", for: key, generation: observationGeneration, cg: quartzFrame,
                    detail: "classification=\(classification) decision=\(decision) age=\(age) retries=\(session.reliftCount) standoffRounds=\(session.standoffRounds)")
            }
        }
        #endif
        let candidate = WindowLiftCGCandidate(
            key: key,
            quartzFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: appKitFrame,
                primaryScreenHeight: context.primaryScreenHeight
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: observationGeneration,
            confirmedLift: confirmedLift
        )
        return true
    }

    func reconcileContexts(_ contexts: [WindowLiftAvoidanceContext]) {
        guard canMutateSessions(), contexts != lastContexts else { return }
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        let retired = Set(sessionContexts.compactMap { contexts.contains($0.value) ? nil : $0.key })
        lastContexts = contexts
        if !retired.isEmpty { restoreWindowsAndClearSessions(retired, reason: "displayContextRetired") }
        updatePollTimerLifecycle()
    }

    private func handleScanResult(
        _ result: WindowLiftCGScanResult,
        contexts: [WindowLiftAvoidanceContext],
        scanGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard scanGeneration == self.scanGeneration else { return }
        defer {
            scanTask = nil
            scanInFlight = false
            releaseUnusedObservationWatermarks()
            finishEventPollAfterScan()
        }
        // 已经排队的扫描回调也要过闸门：光给几个清理函数加 guard 挡不住在飞的工作。
        guard canMutateSessions() else { return }
        guard hostContexts() == contexts else { return }
        guard restoreTask == nil else { return }

        if let liveWindowKeys = result.liveWindowKeys {
            pruneDeadWindowStates(
                liveWindowKeys: liveWindowKeys,
                observationGeneration: observationGeneration
            )
        }
        let reconciledKeys = reconcileTrackedFrames(
            result.onScreenFrames,
            contexts: contexts,
            observationGeneration: observationGeneration
        )

        // 每块屏各自的候选；跨屏窗口只归面积主体所在的那块屏。只有前台 app 的窗口会抬，
        // 所以按屏序取第一个能过全部闸的候选即可。
        let screenCGFrames = contexts.map(\.screenCGFrame)
        for (index, context) in contexts.enumerated() {
            guard let candidate = result.candidatesByScreenIndex[index],
                  WindowLiftAvoidance.owningContextIndex(for: candidate.quartzFrame, screenCGFrames: screenCGFrames) == index,
                  !reconciledKeys.contains(candidate.key) else { continue }
            if handleScanCandidate(
                candidate,
                context: context,
                observationGeneration: observationGeneration
            ) {
                return
            }
        }
    }

    /// 返回 true = 这个候选已被处理（抬起或已在会话里），后面的屏不用再看。
    private func handleScanCandidate(
        _ candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard pendingRestorations[candidate.key] == nil else { return true }
        guard acceptObservation(
            for: candidate.key,
            generation: observationGeneration
        ) else {
            return false
        }
        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: candidate.quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        var carriedStandoffRounds: Int?
        if let suppressed = suppressedFrames[candidate.key] {
            #if DEBUG
            let classification = WindowLiftAvoidance.frameClassification(
                of: appKitFrame,
                nativeFrame: suppressed.nativeFrame,
                targetFrame: suppressed.targetFrame
            )
            traceClassification(classification, for: candidate.key)
            #endif
            switch suppressed.decision(
                for: appKitFrame, geometry: context.geometry,
                includesTiles: includesTiles, at: uptime()
            ) {
            case .hold:
                return false
            case .restart:
                break
            case let .reassert(rounds):
                carriedStandoffRounds = rounds
            }
        }
        guard let targetFrame = context.geometry.liftTargetFrame(
                  for: appKitFrame,
                  includesTiles: includesTiles
              ),
              let app = system.app(candidate.key.pid),
              app.isActive,
              !app.isTerminated,
              app.activationPolicy == .regular || app.activationPolicy == .accessory else {
            return false
        }
        if suppressedFrames[candidate.key] != nil {
            clearSuppression(for: candidate.key)
            updatePollTimerLifecycle()
            #if DEBUG
            if traceEnabled {
                logger.info(
                    "lift trace suppression cleared pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public)"
                )
            }
            #endif
        }

        let operationGeneration = observationGeneration
        let event: WindowLiftAvoidance.Event
        if let carriedStandoffRounds, states[candidate.key] == nil {
            event = .detourReturnObserved(
                generation: operationGeneration,
                at: uptime(),
                nativeFrame: appKitFrame,
                targetFrame: targetFrame,
                standoffRounds: carriedStandoffRounds
            )
            // A capped return parks the window in `.abandoned` without a write; the tracked
            // observation needs its frames to see the user's later external frame, or the cap
            // never clears.
            managedFrames[candidate.key] = ManagedFrames(
                nativeAppKit: appKitFrame, targetAppKit: targetFrame,
                primaryScreenHeight: context.primaryScreenHeight,
                processGeneration: system.generation(candidate.key.pid),
                restoresSettledTarget: false
            )
        } else {
            event = .maximizedDetected(
                generation: operationGeneration,
                at: uptime(),
                nativeFrame: appKitFrame,
                targetFrame: targetFrame
            )
        }
        let transition = WindowLiftAvoidance.reduce(
            state: states[candidate.key] ?? .idle,
            event: event
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: operationGeneration
        )
        return true
    }

    private func reconcileTrackedFrames(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        observationGeneration: UInt64
    ) -> Set<WindowLiftAvoidance.WindowKey> {
        var reconciled: Set<WindowLiftAvoidance.WindowKey> = []
        for key in Array(states.keys) {
            guard let quartzFrame = quartzFrames[key],
                  let context = sessionContexts[key], contexts.contains(context) else { continue }
            if handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            ) {
                reconciled.insert(key)
            }
        }
        return reconciled
    }

    private func acceptObservation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64
    ) -> Bool {
        guard generation > (observationWatermarks[key] ?? 0) else { return false }
        observationWatermarks[key] = generation
        return true
    }

    private func apply(
        _ transition: WindowLiftAvoidance.Transition,
        for candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        operationGeneration: UInt64,
        confirmedLift: ConfirmedLift? = nil
    ) {
        sessionContexts[candidate.key] = context
        if transition.action == .clear {
            // Read the era off the state the external frame is about to clear.
            let userEra = WindowLiftAvoidance.externalFrameIsUserEra(
                state: states[candidate.key] ?? .idle,
                at: uptime()
            )
            #if DEBUG
            reportDiagnostic("tracking ended", for: candidate.key, generation: operationGeneration, cg: candidate.quartzFrame,
                             detail: "reason=externalFrame suppression=\(userEra ? "untilNative" : "afterAppAnswer")")
            #endif
            clearManagedSession(
                for: candidate.key,
                cancelWriter: true,
                reason: "reducerClear",
                suppression: userEra ? .untilNative(userEra: true) : .afterAppAnswer
            )
            return
        }
        store(transition.state, for: candidate.key)
        switch transition.action {
        case .none:
            break
        case .clear:
            break
        #if DEBUG
        case let .abandon(reason):
            logger.error(
                "lift abandoned pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public) reason=\(reason.diagnosticDescription, privacy: .public)"
            )
        #else
        case .abandon:
            break
        #endif
        case let .write(targetFrame, rollbackFrame, generation, isRelift):
            guard generation == operationGeneration else { return }
            beginWrite(
                candidate: candidate,
                nativeFrame: rollbackFrame,
                targetFrame: targetFrame,
                context: context,
                generation: generation,
                isRelift: isRelift,
                confirmedLift: confirmedLift
            )
        }
    }

    private func beginWrite(
        candidate: WindowLiftCGCandidate,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        context: WindowLiftAvoidanceContext,
        generation: UInt64,
        isRelift: Bool,
        confirmedLift: ConfirmedLift?
    ) {
        let key = candidate.key
        guard case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return
        }
        guard let currentProcess = system.generation(key.pid),
              managedFrames[key]?.processGeneration.map({ $0 == currentProcess }) ?? true else {
            finishOperation(for: key, generation: generation, outcome: .transientValidation(.processIdentityUnavailable))
            return
        }
        let frames = ManagedFrames(
            nativeAppKit: nativeFrame,
            targetAppKit: targetFrame,
            primaryScreenHeight: context.primaryScreenHeight,
            processGeneration: currentProcess,
            restoresSettledTarget: false
        )
        managedFrames[key] = frames
        let nativeQuartz = frames.nativeQuartz
        let targetQuartz = frames.targetQuartz
        pendingValidations[key] = PendingValidation(generation: generation, confirmedLift: confirmedLift)

        let animate = usesAnimatedLift
        let reader = self.reader
        let probe = windowProbe
        let writeIdentity = WriteWindowIdentity(key: key, generation: currentProcess, system: system)
        var drains = writeDrainTasks.removeValue(forKey: key).map { Array($0.values) } ?? []
        if let previousWriter = writeTasks.removeValue(forKey: key) {
            previousWriter.cancel()
            drains.append(previousWriter)
        }
        let task = Task.detached { [weak self] in
            for drain in drains {
                await drain.value
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let mayBegin = await MainActor.run { [weak self] in
                self?.canContinueOperation(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayBegin, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled,
                                          diagnosticReason: "beforeValidation")
                }
                return
            }

            let detectedAt = ProcessInfo.processInfo.systemUptime
            let cancellation = OperationCancellation()
            let budget = OperationReadBudget(maximumDuration: 1, cancellation: cancellation)
            let validation = await Self.validatedHandle(
                reader: reader,
                candidate: candidate,
                detectedAt: detectedAt, probe: probe, cancellation: cancellation, budget: budget
            )
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let handle: AXWindowHandle
            switch validation {
            case let .ready(validatedHandle):
                handle = validatedHandle
            case let .transient(stage, frames):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .transientValidation(stage, frames)
                    )
                }
                return
            case let .unsupported(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .unsupportedValidation(stage)
                    )
                }
                return
            }

            let element = AXElementKey(e: handle.element)
            let admittedFrames = await MainActor.run { [weak self] in
                self?.admitAXWrite(
                    for: key,
                    generation: generation,
                    context: context,
                    element: element
                )
            }
            guard let admittedFrames, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled,
                                          diagnosticReason: "beforeWrite")
                }
                return
            }

            let outcome = await Self.write(
                reader: reader,
                element: element.e,
                nativeFrame: nativeQuartz,
                targetFrame: targetQuartz,
                animated: animate,
                initialReliftCount: attempt.reliftCount,
                primaryScreenHeight: context.primaryScreenHeight,
                cancellation: cancellation, budget: budget,
                writeIdentity: writeIdentity,
                canRecover: { [weak self] in
                    await self?.canRecoverAdmittedWrite(for: key, generation: generation, context: context) ?? false
                }
            )
            await MainActor.run { [weak self] in
                self?.finishOperation(for: key, generation: generation, outcome: outcome, restorationFrames: admittedFrames)
            }
        }
        writeTasks[key] = task
        #if DEBUG
        if isRelift {
            logger.notice(
                "lift relift begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(attempt.reliftCount, privacy: .public)"
            )
        } else if traceEnabled {
            logger.info(
                "lift trace begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) generation=\(generation, privacy: .public) animated=\(animate, privacy: .public)"
            )
        }
        #endif
        updateTrackedProbeLifecycle()
    }

    nonisolated private static func validatedHandle(
        reader: AXWindowReader,
        candidate: WindowLiftCGCandidate,
        detectedAt: TimeInterval, probe: any WindowLiftWindowProbing,
        cancellation: OperationCancellation, budget: OperationReadBudget
    ) async -> ValidationOutcome {
        let schedule = WindowLiftAvoidance.PollSchedule.standard
        var lastTransient = ValidationOutcome.transient(.handleUnavailable)
        for index in schedule.deadlines.indices {
            guard !Task.isCancelled, budget.canContinue else { return lastTransient }
            let elapsed = ProcessInfo.processInfo.systemUptime - detectedAt
            if let delay = schedule.remainingDelay(for: index, elapsed: elapsed), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, budget.canContinue else { return lastTransient }
            let sampleBudget = OperationReadBudget(maximumDuration: budget.remaining, cancellation: cancellation)
            guard let result = await AsyncWorkScope.performBlocking(on: geometryQueue, cancellation: cancellation, operation: {
                guard sampleBudget.canContinue else { return ValidationOutcome.transient(.handleUnavailable) }
                return validationSample(reader: reader.withOperationBudget(sampleBudget), candidate: candidate, probe: probe,
                    isInitial: index == schedule.deadlines.startIndex,
                    isFinal: index == schedule.deadlines.index(before: schedule.deadlines.endIndex))
            }) else { return lastTransient }
            switch result {
            case .transient: lastTransient = result
            case .ready, .unsupported: return result
            }
        }
        return lastTransient
    }

    nonisolated private static func validationSample(
        reader: AXWindowReader, candidate: WindowLiftCGCandidate, probe: any WindowLiftWindowProbing,
        isInitial: Bool, isFinal: Bool
    ) -> ValidationOutcome {
        guard let confirmedCGFrame = probe.frames(for: [candidate.key])[candidate.key] else {
            return .transient(.frameUnavailable)
        }
        guard let handle = reader.captureHandle(forPID: candidate.key.pid, cgWindowID: candidate.key.cgWindowID,
                                                messagingTimeout: windowLiftAXMessagingTimeout) else {
            return .transient(.handleUnavailable)
        }
        let element = handle.element
        guard let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: element, maxAttempts: 1) else {
            return .transient(.roleUnavailable)
        }
        guard role == kAXWindowRole as String else { return .unsupported(.unsupportedRole) }
        if reader.boolAttribute("AXFullScreen" as CFString, from: element, maxAttempts: 1) == true {
            return isFinal ? .unsupported(.fullscreen) : .transient(.fullscreen)
        }
        if reader.boolAttribute(kAXMinimizedAttribute as CFString, from: element, maxAttempts: 1) == true {
            return isFinal ? .unsupported(.minimized) : .transient(.minimized)
        }
        guard let confirmedAXFrame = reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout) else {
            return .transient(.frameUnavailable, ValidationFrames(cg: confirmedCGFrame, ax: nil))
        }
        switch reader.frameSettableStatus(of: element, messagingTimeout: windowLiftAXMessagingTimeout).size {
        case .settable: break
        case .notSettable: return .unsupported(.sizeNotSettable)
        case .unread: return .transient(.capabilityUnavailable)
        }
        guard WindowLiftAvoidance.samplesAreStable(initialCGFrame: candidate.quartzFrame,
            confirmedCGFrame: confirmedCGFrame, confirmedAXFrame: confirmedAXFrame) else {
            return .transient(WindowLiftAvoidance.samplesAreStable(confirmedCGFrame, comparedTo: candidate.quartzFrame)
                ? .frameMismatch : .candidateMoved, ValidationFrames(cg: confirmedCGFrame, ax: confirmedAXFrame))
        }
        return isInitial ? .transient(.frameMismatch) : .ready(handle)
    }

    nonisolated private static func writeSize(
        _ size: CGSize, reader: AXWindowReader, element: AXUIElement, expectedFrame: CGRect,
        nativeFrame: CGRect, cancellation: OperationCancellation, budget: OperationReadBudget,
        managedWriteFrames: WindowLiftWriteFrames,
        writeIdentity: WriteWindowIdentity,
        rollbackOnExpiry: Bool
    ) async -> (AXWindowFrameWriteResult, WindowLiftWriteFrames) {
        let elementKey = AXElementKey(e: element)
        var frames = managedWriteFrames
        let (result, attemptedFrame) = await AsyncWorkScope.performBlocking(on: geometryQueue, cancellation: cancellation) {
            let reader = reader.withOperationBudget(budget)
            var attemptedFrame: CGRect?
            let result = reader.setSize(size, for: elementKey.e,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: expectedFrame, expectedWindowID: writeIdentity.key.cgWindowID,
                onAttempt: { attemptedFrame = $0 },
                checkWriteAdmission: {
                    guard !cancellation.isCancelled, budget.canContinue else { return .operationBudgetExhausted }
                    return writeIdentity.processMatches ? nil : .windowIdentityChanged
                })
            return (result, attemptedFrame)
        } ?? (AXWindowFrameWriteResult.failure(reason: .initialFrameUnavailable, rollback: .notRequested), nil)
        if let attemptedFrame {
            frames.attempted = attemptedFrame
            if case let .success(actualFrame) = result { frames.acknowledged = actualFrame }
        }
        guard rollbackOnExpiry, !cancellation.isCancelled, !budget.canContinue,
              case let .failure(reason, rollback) = result,
              rollback == .notRequested, reason.mayHaveMutatedWindow else { return (result, frames) }
        let cleanup = await rollbackManagedFrame(reader: reader, element: element,
            nativeFrame: nativeFrame, currentFrames: frames.candidates, writeIdentity: writeIdentity)
        return (.failure(reason: reason, rollback: cleanup), frames)
    }

    nonisolated private static func write(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        animated: Bool,
        initialReliftCount: Int,
        primaryScreenHeight: CGFloat,
        cancellation: OperationCancellation, budget: OperationReadBudget,
        writeIdentity: WriteWindowIdentity,
        canRecover: @Sendable () async -> Bool
    ) async -> OperationOutcome {
        let elementKey = AXElementKey(e: element)
        var managedWriteFrames = WindowLiftWriteFrames()

        func writeSize(_ size: CGSize, matching expectedFrame: CGRect, budget: OperationReadBudget,
                       rollbackOnExpiry: Bool = true) async -> AXWindowFrameWriteResult {
            let (result, frames) = await Self.writeSize(size, reader: reader, element: element,
                expectedFrame: expectedFrame, nativeFrame: nativeFrame, cancellation: cancellation, budget: budget,
                managedWriteFrames: managedWriteFrames, writeIdentity: writeIdentity, rollbackOnExpiry: rollbackOnExpiry)
            managedWriteFrames = frames
            return result
        }

        func cancelWrite(after result: AXWindowFrameWriteResult? = nil) async -> OperationOutcome {
            let rechecksNative: Bool
            if case .some(.failure(.writeFailed(.size, .cannotComplete), _)) = result {
                rechecksNative = true
            } else {
                rechecksNative = false
            }
            let rollback = await rollbackCancelledWrite(reader: reader, element: element,
                nativeFrame: nativeFrame, attemptedFrames: managedWriteFrames.candidates,
                writeIdentity: writeIdentity, rechecksNative: rechecksNative)
            return .cancelledWrite(rollback, managedWriteFrames: managedWriteFrames)
        }

        if !animated {
            let result = await writeSize(targetFrame.size, matching: nativeFrame, budget: budget)
            if Task.isCancelled { return await cancelWrite(after: result) }
            switch result {
            case let .success(actualFrame):
                return await completedOrRolledBack(
                    reader: reader,
                    element: element,
                    actualFrame: actualFrame,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    managedWriteFrames: managedWriteFrames,
                    anomalies: [],
                    primaryScreenHeight: primaryScreenHeight,
                    writeIdentity: writeIdentity
                )

            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    lastAcknowledgedFrame: nativeFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                #if DEBUG
                let anomalies = [WriteAnomaly(
                    reason: reason,
                    rollback: rollback,
                    decision: decision,
                    progress: 1
                )]
                #else
                let anomalies: [WriteAnomaly] = []
                #endif
                switch decision {
                case let .complete(actualFrame):
                    return await completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: initialReliftCount,
                        managedWriteFrames: managedWriteFrames,
                        anomalies: anomalies,
                        primaryScreenHeight: primaryScreenHeight,
                        writeIdentity: writeIdentity
                    )
                case let .continueFromActual(actualFrame):
                    // 停滞：写入可能尚未被窗口应用（1x 屏迟到应用）。等一拍再确认一次，
                    // 仍未到位才清会话交还给下一轮扫描。
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { return await cancelWrite() }
                    let settledFrame = await AsyncWorkScope.performBlocking(on: geometryQueue, cancellation: cancellation, operation: {
                        reader.withOperationBudget(budget).frame(of: elementKey.e, messagingTimeout: windowLiftAXMessagingTimeout)
                    }) ?? nil
                    if Task.isCancelled { return await cancelWrite() }
                    if let settledFrame,
                       WindowLiftAvoidance.framesMatch(settledFrame, targetFrame) {
                        return await completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: settledFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: initialReliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight,
                            writeIdentity: writeIdentity
                        )
                    }
                    return .externalFrame(actualFrame, anomalies: anomalies)
                case let .clearSession(frame),
                     let .restartFromNative(frame, _):
                    // Instant mode owns exactly one AX write. A mismatch that did not mutate the
                    // window clears this attempt and lets the next CG observation start cleanly.
                    return .externalFrame(frame, anomalies: anomalies)
                case let .reliftLimitReached(frame, count):
                    return .reliftLimitReached(
                        frame,
                        reliftCount: count,
                        anomalies: anomalies
                    )
                case .abandonWriteFailed:
                    return .failed(
                        reason: reason,
                        rollback: rollback,
                        progress: 1,
                        reliftCount: initialReliftCount,
                        managedWriteFrames: managedWriteFrames,
                        anomalies: anomalies
                    )
                }
            }
        }

        let frameInterval = 1.0 / WindowLiftAvoidance.animationFramesPerSecond
        var segmentStartFrame = nativeFrame
        var segmentProgressStart = 0.0
        let animationStartedAt = ProcessInfo.processInfo.systemUptime
        var nextDeadline = animationStartedAt + frameInterval
        var expectedFrame = nativeFrame
        var confirmedIntermediateFrame: CGRect?
        var reliftCount = initialReliftCount
        var anomalies: [WriteAnomaly] = []
        // 最终帧允许有限次停滞重试：慢应用屏上写入生效晚于回读。
        var finalStallRetries = 0
        let maxFinalStallRetries = 3

        func finishInterruptedAnimation(after result: AXWindowFrameWriteResult, progress: Double) async -> OperationOutcome? {
            guard case .failure(.initialFrameUnavailable, .notRequested) = result,
                  let confirmedFrame = confirmedIntermediateFrame,
                  WindowLiftAvoidance.framesMatch(expectedFrame, confirmedFrame),
                  !WindowLiftAvoidance.framesMatch(confirmedFrame, nativeFrame),
                  !WindowLiftAvoidance.framesMatch(confirmedFrame, targetFrame) else { return nil }

            func recordRecovery(_ reason: AXWindowFrameWriteFailure, _ rollback: AXWindowFrameRollbackResult,
                                _ decision: WindowLiftAvoidance.AnimationWriteFailureDecision) {
                Self.recordBounded(WriteAnomaly(reason: reason, rollback: rollback, decision: decision, progress: progress),
                                   in: &anomalies)
            }

            func failedRecovery(_ reason: AXWindowFrameWriteFailure, _ rollback: AXWindowFrameRollbackResult) -> OperationOutcome {
                recordRecovery(reason, rollback, .abandonWriteFailed)
                return .failed(reason: reason, rollback: rollback, progress: progress,
                               reliftCount: reliftCount, managedWriteFrames: managedWriteFrames, anomalies: anomalies)
            }

            func cleanupRecovery(_ reason: AXWindowFrameWriteFailure) async -> OperationOutcome {
                let rollback = await rollbackManagedFrame(reader: reader, element: element, nativeFrame: nativeFrame,
                    currentFrames: managedWriteFrames.candidates, writeIdentity: writeIdentity, sizeOnly: true)
                switch rollback {
                case .failed(.windowIdentityChanged, _):
                    return failedRecovery(.windowIdentityChanged, .notRequested)
                case let .failed(.initialFrameMismatch(_, actualFrame), _):
                    if Task.isCancelled { return .cancelledWrite(.notRequested, managedWriteFrames: managedWriteFrames) }
                    recordRecovery(reason, rollback, .clearSession(preservingFrame: actualFrame))
                    return .externalFrame(actualFrame, anomalies: anomalies)
                default:
                    return Task.isCancelled ? .cancelledWrite(rollback, managedWriteFrames: managedWriteFrames) :
                        failedRecovery(reason, rollback)
                }
            }

            let schedule = WindowLiftAvoidance.PollSchedule.standard
            let startedAt = ProcessInfo.processInfo.systemUptime
            let recoveryBudget = budget.limited(to: WindowLiftAvoidance.animationDuration)
            for index in schedule.deadlines.indices {
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                if let delay = schedule.remainingDelay(for: index, elapsed: elapsed), delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard writeIdentity.processMatches else {
                    return failedRecovery(.windowIdentityChanged, .notRequested)
                }
                guard !Task.isCancelled, recoveryBudget.canContinue, await canRecover(),
                      !Task.isCancelled else { break }
                let result = await writeSize(targetFrame.size, matching: confirmedFrame,
                    budget: recoveryBudget, rollbackOnExpiry: false)
                guard writeIdentity.processMatches else {
                    return failedRecovery(.windowIdentityChanged, .notRequested)
                }
                switch result {
                case .failure(.windowIdentityChanged, _):
                    return failedRecovery(.windowIdentityChanged, .notRequested)
                case let .success(actualFrame):
                    if Task.isCancelled {
                        return await cleanupRecovery(.initialFrameUnavailable)
                    }
                    recordRecovery(.initialFrameUnavailable, .notRequested, .complete(actualFrame: actualFrame))
                    return await completedOrRolledBack(reader: reader, element: element, actualFrame: actualFrame,
                        nativeFrame: nativeFrame, targetFrame: targetFrame, reliftCount: reliftCount,
                        managedWriteFrames: managedWriteFrames,
                        anomalies: anomalies, primaryScreenHeight: primaryScreenHeight,
                        writeIdentity: writeIdentity, sizeOnlyRollback: true)
                case .failure(.initialFrameUnavailable, .notRequested):
                    continue
                case let .failure(.initialFrameMismatch(_, actualFrame), _):
                    if Task.isCancelled { return .cancelledWrite(.notRequested, managedWriteFrames: managedWriteFrames) }
                    recordRecovery(.initialFrameUnavailable, .notRequested, .clearSession(preservingFrame: actualFrame))
                    return .externalFrame(actualFrame, anomalies: anomalies)
                case let .failure(reason, _):
                    if Task.isCancelled, case .writeFailed(.size, .cannotComplete) = reason {
                        return await cancelWrite(after: result)
                    }
                    return await cleanupRecovery(reason)
                }
            }
            return await cleanupRecovery(.initialFrameUnavailable)
        }

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let animationElapsed = now - animationStartedAt
            if animationElapsed >= WindowLiftAvoidance.animationDuration {
                let result = await writeSize(targetFrame.size, matching: expectedFrame, budget: budget)
                if let recovery = await finishInterruptedAnimation(after: result, progress: 1) { return recovery }
                if Task.isCancelled { return await cancelWrite(after: result) }
                switch result {
                case let .success(actualFrame):
                    return await completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        managedWriteFrames: managedWriteFrames,
                        anomalies: anomalies,
                        primaryScreenHeight: primaryScreenHeight,
                        writeIdentity: writeIdentity
                    )

                case let .failure(reason, rollback):
                    let decision = animationFailureDecision(
                        for: reason,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        lastAcknowledgedFrame: expectedFrame,
                        primaryScreenHeight: primaryScreenHeight
                    )
                    switch decision {
                    case let .complete(actualFrame):
                        return await completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight,
                            writeIdentity: writeIdentity
                        )
                    case let .continueFromActual(actualFrame):
                        // 最终帧停滞/轨迹内：等一拍重写，有限次后才判失败。
                        if finalStallRetries < maxFinalStallRetries {
                            finalStallRetries += 1
                            expectedFrame = actualFrame
                            try? await Task.sleep(
                                nanoseconds: UInt64(frameInterval * 1_000_000_000)
                            )
                            continue
                        }
                        let anomaly = WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        )
                        recordBounded(anomaly, in: &anomalies)
                        let finalRollback = await rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            managedWriteFrames: managedWriteFrames,
                            writeIdentity: writeIdentity
                        )
                        return .failed(
                            reason: reason,
                            rollback: finalRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies
                        )
                    case let .clearSession(frame):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(_, nextReliftCount):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = await rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            managedWriteFrames: managedWriteFrames,
                            writeIdentity: writeIdentity
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: nextReliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies
                        )
                    case let .reliftLimitReached(frame, count):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = await rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            managedWriteFrames: managedWriteFrames,
                            writeIdentity: writeIdentity
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let sleepDuration = max(0, nextDeadline - now)
            if sleepDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
            if Task.isCancelled { return await cancelWrite() }

            let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
            guard elapsed < WindowLiftAvoidance.animationDuration else { continue }
            let overallProgress = max(0, elapsed / WindowLiftAvoidance.animationDuration)
            let progress = WindowLiftAvoidance.rebasedAnimationProgress(
                overallProgress,
                startingAt: segmentProgressStart
            )
            let attemptedFrame = monotonicAttemptedFrame(
                scheduled: WindowLiftAvoidance.interpolatedFrame(
                    from: segmentStartFrame,
                    to: targetFrame,
                    progress: progress
                ),
                current: expectedFrame,
                target: targetFrame
            )
            // 尺寸取整：1x 屏只能表示整数点，小数请求会被取整/忽略，撞上 2pt 验证容差。
            let attemptedSize = CGSize(
                width: attemptedFrame.width.rounded(),
                height: attemptedFrame.height.rounded()
            )
            let result = await writeSize(attemptedSize, matching: expectedFrame, budget: budget)
            if let recovery = await finishInterruptedAnimation(after: result, progress: overallProgress) { return recovery }
            if Task.isCancelled { return await cancelWrite(after: result) }
            switch result {
            case let .success(actualFrame):
                if managedWriteFrames.acknowledged == actualFrame,
                   !WindowLiftAvoidance.framesMatch(actualFrame, expectedFrame) {
                    confirmedIntermediateFrame = actualFrame
                }
                expectedFrame = actualFrame
                if Task.isCancelled { return await cancelWrite() }
            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: reliftCount,
                    lastAcknowledgedFrame: expectedFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                if case let .continueFromActual(actualFrame) = decision {
                    // 停滞或轨迹内自愈：不算异常，进度表下一帧自然补上步长。
                    expectedFrame = actualFrame
                } else {
                    let anomaly = WriteAnomaly(
                        reason: reason,
                        rollback: rollback,
                        decision: decision,
                        progress: overallProgress
                    )
                    recordBounded(anomaly, in: &anomalies)
                    switch decision {
                    case let .complete(actualFrame):
                        return await completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight,
                            writeIdentity: writeIdentity
                        )
                    case .continueFromActual:
                        break
                    case let .clearSession(frame):
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        segmentStartFrame = frame
                        expectedFrame = frame
                        confirmedIntermediateFrame = nil
                        managedWriteFrames = WindowLiftWriteFrames()
                        reliftCount = nextReliftCount
                        segmentProgressStart = overallProgress
                        continue
                    case let .reliftLimitReached(frame, count):
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        let safeRollback = await rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            managedWriteFrames: managedWriteFrames,
                            writeIdentity: writeIdentity
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: overallProgress,
                            reliftCount: reliftCount,
                            managedWriteFrames: managedWriteFrames,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let elapsedAfterWrite = max(
                0,
                ProcessInfo.processInfo.systemUptime - animationStartedAt
            )
            let completedSlots = floor(elapsedAfterWrite / frameInterval)
            nextDeadline = animationStartedAt + (completedSlots + 1) * frameInterval
        }
    }

    nonisolated private static func completedOrRolledBack(
        reader: AXWindowReader,
        element: AXUIElement,
        actualFrame: CGRect,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        managedWriteFrames: WindowLiftWriteFrames,
        anomalies: [WriteAnomaly],
        primaryScreenHeight: CGFloat,
        writeIdentity: WriteWindowIdentity,
        sizeOnlyRollback: Bool = false
    ) async -> OperationOutcome {
        guard managedWriteFrames.matches(actualFrame) else { return .externalFrame(actualFrame, anomalies: anomalies) }
        let actualAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: actualFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        let targetAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: targetFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        guard !WindowLiftAvoidance.framesMatch(
            actualAppKit,
            targetAppKit,
            tolerance: WindowLiftAvoidance.verificationTolerance
        ) else {
            return .completed(actualFrame, reliftCount: reliftCount, anomalies: anomalies)
        }

        let reason = AXWindowFrameWriteFailure.verificationMismatch(
            expected: targetFrame,
            actual: actualFrame
        )
        let rollback = await rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrames: managedWriteFrames.candidates,
            writeIdentity: writeIdentity,
            sizeOnly: sizeOnlyRollback
        )
        var finalAnomalies = anomalies
        recordBounded(
            WriteAnomaly(
                reason: reason,
                rollback: rollback,
                decision: .abandonWriteFailed,
                progress: 1
            ),
            in: &finalAnomalies
        )
        return .failed(
            reason: reason,
            rollback: rollback,
            progress: 1,
            reliftCount: reliftCount,
            managedWriteFrames: managedWriteFrames,
            anomalies: finalAnomalies
        )
    }

    nonisolated private static func animationFailureDecision(
        for reason: AXWindowFrameWriteFailure,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        lastAcknowledgedFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> WindowLiftAvoidance.AnimationWriteFailureDecision {
        let failure: WindowLiftAvoidance.AnimationWriteFailure
        switch reason {
        // verificationMismatch 同样携带真实 actual：慢应用屏（1x 外接屏）上写后立刻回读
        // 常拿到旧值，按 terminal 处理会在第一帧 ~2pt 缓动步长上必然放弃。
        case let .initialFrameMismatch(_, actualFrame),
             let .verificationMismatch(_, actualFrame):
            failure = .initialFrameMismatch(actualFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualFrame,
                primaryScreenHeight: primaryScreenHeight
            ))
        default:
            failure = .terminalWriteFailure
        }
        let appKitDecision = WindowLiftAvoidance.animationWriteFailureDecision(
            failure,
            nativeFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: nativeFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            targetFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: targetFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            reliftCount: reliftCount,
            lastAcknowledgedFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: lastAcknowledgedFrame,
                primaryScreenHeight: primaryScreenHeight
            )
        )
        func quartz(_ frame: CGRect) -> CGRect {
            WindowLiftAvoidance.quartzFrame(
                fromAppKit: frame,
                primaryScreenHeight: primaryScreenHeight
            )
        }
        switch appKitDecision {
        case let .complete(frame):
            return .complete(actualFrame: quartz(frame))
        case let .continueFromActual(frame):
            return .continueFromActual(actualFrame: quartz(frame))
        case let .clearSession(frame):
            return .clearSession(preservingFrame: quartz(frame))
        case let .restartFromNative(frame, nextReliftCount):
            return .restartFromNative(
                nativeFrame: quartz(frame),
                nextReliftCount: nextReliftCount
            )
        case let .reliftLimitReached(frame, count):
            return .reliftLimitReached(
                actualFrame: quartz(frame),
                reliftCount: count
            )
        case .abandonWriteFailed:
            return .abandonWriteFailed
        }
    }

    nonisolated private static func recordBounded(
        _ anomaly: WriteAnomaly,
        in anomalies: inout [WriteAnomaly]
    ) {
        #if DEBUG
        if anomalies.count < 4 {
            anomalies.append(anomaly)
        } else {
            // Keep the beginning of the episode and always preserve the newest decision/result.
            anomalies[anomalies.count - 1] = anomaly
        }
        #endif
    }

    /// A recovered trajectory mismatch may already be ahead of the elapsed-time sample. Do not
    /// grow the window back toward the native frame while the schedule catches up.
    nonisolated private static func monotonicAttemptedFrame(
        scheduled: CGRect,
        current: CGRect,
        target: CGRect
    ) -> CGRect {
        func component(_ scheduled: CGFloat, _ current: CGFloat, _ target: CGFloat) -> CGFloat {
            if target < current { return max(target, min(scheduled, current)) }
            if target > current { return min(target, max(scheduled, current)) }
            return target
        }
        return CGRect(
            origin: scheduled.origin,
            size: CGSize(
                width: component(scheduled.width, current.width, target.width),
                height: component(scheduled.height, current.height, target.height)
            )
        )
    }

    nonisolated private static func rollbackManagedFrame(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentFrames: [CGRect],
        writeIdentity: WriteWindowIdentity,
        sizeOnly: Bool = false
    ) async -> AXWindowFrameRollbackResult {
        let elementKey = AXElementKey(e: element)
        return await Task.detached {
            await AsyncWorkScope.performBlocking(on: geometryQueue) {
                let reader = reader.withOperationBudget(OperationReadBudget(maximumDuration: 1, cancellation: OperationCancellation()))
                return rollbackManagedFrameSynchronously(reader: reader, element: elementKey.e,
                    nativeFrame: nativeFrame, currentFrames: currentFrames, writeIdentity: writeIdentity, sizeOnly: sizeOnly)
            } ?? .failed(reason: .verificationUnavailable, actualFrame: nil)
        }.value
    }

    nonisolated private static func rollbackManagedFrameSynchronously(
        reader: AXWindowReader, element: AXUIElement, nativeFrame: CGRect, currentFrames: [CGRect],
        writeIdentity: WriteWindowIdentity, sizeOnly: Bool
    ) -> AXWindowFrameRollbackResult {
        guard writeIdentity.processMatches else { return .failed(reason: .windowIdentityChanged, actualFrame: nil) }
        guard let currentFrame = reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout) else {
            return .failed(reason: .verificationUnavailable, actualFrame: nil)
        }
        if WindowLiftAvoidance.framesMatch(currentFrame, nativeFrame) {
            return .restored(actualFrame: currentFrame)
        }
        guard AXWindowFrameRollbackPolicy.accepts(currentFrame, attemptedFrames: currentFrames,
                                                  tolerance: WindowLiftAvoidance.verificationTolerance) else {
            return .failed(reason: .initialFrameMismatch(expected: currentFrames.last ?? nativeFrame, actual: currentFrame),
                           actualFrame: currentFrame)
        }
        let result: AXWindowFrameWriteResult
        if sizeOnly {
            result = reader.setSize(nativeFrame.size, for: element, messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance, onlyIfCurrentMatches: currentFrame,
                expectedWindowID: writeIdentity.key.cgWindowID,
                checkWriteAdmission: { writeIdentity.processMatches ? nil : .windowIdentityChanged })
        } else {
            result = reader.setFrame(nativeFrame, for: element, messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance, onlyIfCurrentMatches: currentFrame,
                restoreOnFailureTo: currentFrame, expectedWindowID: writeIdentity.key.cgWindowID,
                checkWriteAdmission: { writeIdentity.processMatches ? nil : .windowIdentityChanged })
        }
        switch result {
        case let .success(actualFrame):
            return .restored(actualFrame: actualFrame)
        case let .failure(reason, _):
            if reason == .windowIdentityChanged { return .failed(reason: reason, actualFrame: nil) }
            return .failed(
                reason: reason,
                actualFrame: reader.frame(
                    of: element,
                    messagingTimeout: windowLiftAXMessagingTimeout
                )
            )
        }
    }

    nonisolated private static func rollbackAfterAnimationFailure(
        _ rollback: AXWindowFrameRollbackResult,
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        managedWriteFrames: WindowLiftWriteFrames,
        writeIdentity: WriteWindowIdentity
    ) async -> AXWindowFrameRollbackResult {
        guard rollback == .notRequested, !managedWriteFrames.isEmpty else {
            return rollback
        }
        return await rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrames: managedWriteFrames.candidates,
            writeIdentity: writeIdentity
        )
    }

    private enum CancellationRollbackProbe {
        case confirmedNative(CGRect)
        case finished(AXWindowFrameRollbackResult)
    }

    nonisolated private static func rollbackCancelledWrite(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        attemptedFrames: [CGRect],
        writeIdentity: WriteWindowIdentity,
        rechecksNative: Bool
    ) async -> AXWindowFrameRollbackResult {
        guard !attemptedFrames.isEmpty else { return .notRequested }
        let elementKey = AXElementKey(e: element)
        return await Task.detached {
            let budget = OperationReadBudget(maximumDuration: 1, cancellation: OperationCancellation())
            let reader = reader.withOperationBudget(budget)
            let deadlines = rechecksNative ? WindowLiftAvoidance.PollSchedule.standard.deadlines : [0]
            let startedAt = ProcessInfo.processInfo.systemUptime
            for (index, deadline) in deadlines.enumerated() {
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let delay = min(deadline - elapsed, budget.remaining)
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard budget.canContinue,
                      let probe = await AsyncWorkScope.performBlocking(on: geometryQueue, cancellation: budget.cancellation, operation: {
                          rollbackCancelledWriteSynchronously(reader: reader, element: elementKey.e,
                              nativeFrame: nativeFrame, attemptedFrames: attemptedFrames, writeIdentity: writeIdentity)
                      }) else { break }
                switch probe {
                case let .finished(rollback):
                    return rollback
                case let .confirmedNative(frame):
                    if index == deadlines.count - 1 { return .restored(actualFrame: frame) }
                }
            }
            return .failed(reason: .verificationUnavailable, actualFrame: nil)
        }.value
    }

    nonisolated private static func rollbackCancelledWriteSynchronously(
        reader: AXWindowReader, element: AXUIElement, nativeFrame: CGRect, attemptedFrames: [CGRect],
        writeIdentity: WriteWindowIdentity
    ) -> CancellationRollbackProbe {
        guard writeIdentity.processMatches else { return .finished(.failed(reason: .windowIdentityChanged, actualFrame: nil)) }
        guard let currentFrame = reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout) else {
            return .finished(.failed(reason: .verificationUnavailable, actualFrame: nil))
        }
        if WindowLiftAvoidance.framesMatch(currentFrame, nativeFrame) {
            return .confirmedNative(currentFrame)
        }
        for attemptedFrame in attemptedFrames {
            guard case let .restore(frame) = WindowLiftAvoidance.rollbackDecision(
                originalFrame: nativeFrame,
                attemptedFrame: attemptedFrame,
                currentFrame: currentFrame
            ) else { continue }
            switch reader.setFrame(
                frame,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: attemptedFrame,
                expectedWindowID: writeIdentity.key.cgWindowID,
                checkWriteAdmission: { writeIdentity.processMatches ? nil : .windowIdentityChanged }
            ) {
            case let .success(actualFrame): return .confirmedNative(actualFrame)
            case let .failure(reason, _):
                let actualFrame = reason == .windowIdentityChanged ? nil :
                    reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout)
                return .finished(.failed(reason: reason, actualFrame: actualFrame))
            }
        }
        return .finished(.notRequested)
    }

    private func canContinueOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard let validation = pendingValidations[key], validation.generation == generation,
              pendingRestorations[key] == nil,
              let expected = managedFrames[key]?.processGeneration,
              system.generation(key.pid) == expected,
              hostContexts().contains(context),
              let app = system.app(key.pid), !app.isTerminated,
              !validation.requiresActiveApplication || app.isActive,
              case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return false
        }
        return true
    }

    private func admitAXWrite(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext,
        element: AXElementKey
    ) -> ManagedFrames? {
        guard canContinueOperation(for: key, generation: generation, context: context),
              var frames = managedFrames[key] else { return nil }
        frames.expectedElement = element
        managedFrames[key] = frames
        pendingValidations.removeValue(forKey: key)
        return frames
    }

    private func canRecoverAdmittedWrite(
        for key: WindowLiftAvoidance.WindowKey, generation: UInt64, context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard isEnabled, ensureTrustedOrFreeze(), pendingRestorations[key] == nil,
              pendingValidations[key] == nil, case let .writing(attempt) = states[key],
              attempt.generation == generation,
              let expectedProcess = managedFrames[key]?.processGeneration,
              system.generation(key.pid) == expectedProcess,
              hostContexts().contains(context),
              system.app(key.pid)?.isTerminated == false else { return false }
        return true
    }

    private func finishOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        outcome: OperationOutcome,
        restorationFrames: ManagedFrames? = nil,
        diagnosticReason: String? = nil
    ) {
        var interruptedWriteFrames = WindowLiftWriteFrames()
        var settledTarget = false
        switch outcome {
        case .completed:
            settledTarget = true
        case let .cancelledWrite(.failed(reason, _), frames),
             let .failed(_, .failed(reason, _), _, _, frames, _):
            switch reason {
            case .initialFrameMismatch, .windowIdentityChanged: break
            default: interruptedWriteFrames = frames
            }
        case let .failed(reason, .notRequested, _, _, frames, _) where reason.mayHaveMutatedWindow:
            interruptedWriteFrames = frames
        default:
            break
        }
        let needsInterruptedRestoration = !interruptedWriteFrames.isEmpty
        if var frames = restorationFrames,
           needsInterruptedRestoration || (settledTarget && (pendingRestorations[key] != nil || !canMutateSessions())) {
            let queued = pendingRestorations[key]
            if queued?.hasSameRestorationPlan(as: frames) != false {
                frames.restoresSettledTarget = settledTarget || queued?.restoresSettledTarget == true
                frames.interruptedWriteFrames = interruptedWriteFrames
                frames.partiallyRestoredQuartz = queued?.partiallyRestoredQuartz
                pendingRestorations[key] = frames
            }
        }
        defer {
            if needsInterruptedRestoration, pendingRestorations[key] != nil, canMutateSessions() {
                launchRestoreTask(cancelledWrites: [])
            }
        }
        guard canMutateSessions() else {
            // 取消写任务会走到这里。冻结期间不许它顺手把会话清掉——
            // `.cancelled` / `.transientValidation` 分支都通向 clearManagedSession。
            if let writer = writeTasks.removeValue(forKey: key) { pendingDrains.append(writer) }
            return
        }
        guard case let .writing(attempt) = states[key], attempt.generation == generation else {
            return
        }
        let validation = pendingValidations[key]?.generation == generation
            ? pendingValidations.removeValue(forKey: key) : nil
        writeTasks.removeValue(forKey: key)
        let finishedAt = uptime()

        switch outcome {
        case .cancelled:
            #if DEBUG
            reportDiagnostic("cancelled", for: key, generation: generation, detail: "reason=\(diagnosticReason ?? "taskCancelled")")
            #endif
            clearManagedSession(for: key, cancelWriter: false, reason: "cancelled")

        case let .cancelledWrite(rollback, _):
            #if DEBUG
            reportDiagnostic("cancelled", for: key, generation: generation,
                             detail: "reason=writeCancelled rollback=\(rollback.diagnosticDescription)")
            #endif
            clearManagedSession(for: key, cancelWriter: false, reason: "cancelled")

        case let .transientValidation(stage, samples):
            if stage == .candidateMoved, let confirmedLift = validation?.confirmedLift,
               let expectedProcess = confirmedLift.frames.processGeneration,
               system.generation(key.pid) == expectedProcess {
                #if DEBUG
                reportDiagnostic("validation transient", for: key, generation: generation, cg: samples?.cg, ax: samples?.ax,
                    detail: "stage=\(stage.rawValue) decision=keepConfirmedLift")
                #endif
                observationWatermarks[key] = nextGeneration
                managedFrames[key] = confirmedLift.frames
                store(.lifted(confirmedLift.session), for: key)
                return
            }
            #if DEBUG
            reportDiagnostic("validation transient", for: key, generation: generation, cg: samples?.cg, ax: samples?.ax,
                detail: "stage=\(stage.rawValue) decision=clear")
            #endif
            // Validation has not written the window yet. A moving zoom candidate must return to
            // idle so the next global sample can establish a fresh native frame — except mid
            // standoff, where a plain clear would hand the next lift a fresh budget.
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: stage.rawValue,
                suppression: attempt.standoffRounds > 0 ? .afterAppAnswer : .none
            )

        case let .unsupportedValidation(stage):
            #if DEBUG
            reportDiagnostic("validation rejected", for: key, generation: generation, level: .error,
                             detail: "stage=\(stage.rawValue) decision=abandon")
            #endif
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: attempt.reliftCount
                )
            )
            store(transition.state, for: key)

        case let .externalFrame(actualQuartzFrame, anomalies):
            #if DEBUG
            reportDiagnostic("write interrupted", for: key, generation: generation, ax: actualQuartzFrame,
                             detail: "reason=externalFrame decision=preserve")
            logWriteAnomalies(anomalies, for: key, terminal: false)
            if let frames = managedFrames[key] {
                let actualAppKit = WindowLiftAvoidance.appKitFrame(
                    fromQuartz: actualQuartzFrame,
                    primaryScreenHeight: frames.primaryScreenHeight
                )
                traceClassification(
                    WindowLiftAvoidance.frameClassification(
                        of: actualAppKit,
                        nativeFrame: frames.nativeAppKit,
                        targetFrame: frames.targetAppKit
                    ),
                    for: key
                )
                if traceEnabled {
                    logger.info(
                        "lift trace preserve external pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: actualAppKit), privacy: .public)"
                    )
                }
            }
            #endif
            // An external frame during our own write is never the user era.
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "externalFrame",
                suppression: .afterAppAnswer
            )

        case let .reliftLimitReached(actualQuartzFrame, reliftCount, anomalies):
            #if DEBUG
            reportDiagnostic("retry limit reached", for: key, generation: generation, ax: actualQuartzFrame, level: .error,
                             detail: "decision=abandon retries=\(reliftCount)")
            logWriteAnomalies(anomalies, for: key, terminal: true)
            #endif
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .reliftLimitReached(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)

        case let .failed(reason, rollback, progress, reliftCount, _, anomalies):
            #if DEBUG
            reportDiagnostic("write failed", for: key, generation: generation, level: .error,
                detail: "reason=\(reason.diagnosticDescription) rollback=\(rollback.diagnosticDescription) progress=\(progress) retries=\(reliftCount)")
            logWriteAnomalies(anomalies, for: key, terminal: true)
            #endif
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)

        case let .completed(actualQuartzFrame, reliftCount, anomalies):
            #if DEBUG
            logWriteAnomalies(anomalies, for: key, terminal: false)
            #endif
            guard var frames = managedFrames[key] else { return }
            frames.restoresSettledTarget = true
            managedFrames[key] = frames
            #if DEBUG
            if reportedClearanceLosses.removeValue(forKey: key) != nil || reliftCount > 0 {
                reportDiagnostic("write verified", for: key, generation: generation, ax: actualQuartzFrame,
                                 detail: "retries=\(reliftCount)")
            }
            #endif
            observationWatermarks[key] = nextGeneration
            let actualAppKit = WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualQuartzFrame,
                primaryScreenHeight: frames.primaryScreenHeight
            )
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFinished(
                    generation: generation,
                    at: finishedAt,
                    actualFrame: actualAppKit,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            #if DEBUG
            if reliftCount > attempt.reliftCount {
                logger.notice(
                    "lift relift completed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(reliftCount, privacy: .public)"
                )
            }
            if !WindowLiftAvoidance.framesMatch(actualAppKit, frames.targetAppKit) {
                logger.error(
                    "lift verification mismatch pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public)"
                )
            }
            #endif
        }
        updateTrackedProbeLifecycle()
    }

    #if DEBUG
    private func logWriteAnomalies(
        _ anomalies: [WriteAnomaly],
        for key: WindowLiftAvoidance.WindowKey,
        terminal: Bool
    ) {
        for anomaly in anomalies.prefix(4) {
            let progress = String(format: "%.3f", anomaly.progress)
            let message = "lift animation anomaly pid=\(key.pid) wid=\(key.cgWindowID) progress=\(progress) reason=\(anomaly.reason.diagnosticDescription) decision=\(anomaly.decision.diagnosticDescription) rollback=\(anomaly.rollback.diagnosticDescription)"
            if terminal {
                logger.error("\(message, privacy: .public)")
            } else {
                logger.notice("\(message, privacy: .public)")
            }
        }
    }
    #endif

    private func cancelUnstartedWrites(except activePID: pid_t?) {
        for (key, task) in writeTasks where key.pid != activePID && pendingValidations[key]?.requiresActiveApplication == true {
            task.cancel()
        }
    }

    private func removeStates(forPID pid: pid_t) {
        let keys = Set(states.keys).union(suppressedFrames.keys).filter { $0.pid == pid }
        for key in keys {
            clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
        }
    }

    private func pruneDeadWindowStates(
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>,
        observationGeneration: UInt64
    ) {
        let deadKeys = WindowLiftAvoidance.prunableDeadWindowKeys(
            tracked: Set(states.keys).union(suppressedFrames.keys),
            live: liveWindowKeys,
            observationGeneration: observationGeneration,
            observationWatermarks: observationWatermarks
        )
        for key in deadKeys {
            observationWatermarks[key] = observationGeneration
            clearManagedSession(for: key, cancelWriter: true, reason: "deadWindowPrune")
        }
    }

    private func restoreSettledWindowsAndClearSessions() {
        let keys = Set(states.keys).union(suppressedFrames.keys).union(writeTasks.keys).union(writeDrainTasks.keys)
        restoreWindowsAndClearSessions(keys, reason: "stop")
    }

    private func restoreWindowsAndClearSessions(_ keys: Set<WindowLiftAvoidance.WindowKey>, reason: String) {
        guard canMutateSessions() else { return }
        var cancelledWrites: [Task<Void, Never>] = []
        for key in keys {
            if let task = writeTasks.removeValue(forKey: key) { task.cancel(); cancelledWrites.append(task) }
            cancelledWrites.append(contentsOf: writeDrainTasks.removeValue(forKey: key).map { Array($0.values) } ?? [])
            if let state = states[key], state != .idle,
               pendingRestorations[key] == nil,
               let frames = pendingValidations[key]?.confirmedLift?.frames ?? managedFrames[key] {
                #if DEBUG
                reportDiagnostic("restoration queued", for: key, frames: frames, detail: "reason=\(reason)")
                #endif
                pendingRestorations[key] = frames
            }
            states.removeValue(forKey: key)
            sessionContexts.removeValue(forKey: key)
            managedFrames.removeValue(forKey: key)
            suppressedFrames.removeValue(forKey: key)
            observationWatermarks.removeValue(forKey: key)
            pendingValidations.removeValue(forKey: key)
            #if DEBUG
            lastTraceClassifications.removeValue(forKey: key)
            reportedClearanceLosses.removeValue(forKey: key)
            #endif
        }
        stopTrackedProbe()
        launchRestoreTask(cancelledWrites: cancelledWrites)
        updateTrackedProbeLifecycle()
    }

    private func launchRestoreTask(cancelledWrites: [Task<Void, Never>], budget inheritedBudget: OperationReadBudget? = nil,
                                   preferring newKeys: Set<WindowLiftAvoidance.WindowKey> = []) {
        pendingRestorationDrains.append(contentsOf: cancelledWrites)
        guard !pendingRestorations.isEmpty || !pendingRestorationDrains.isEmpty, restoreTask == nil else {
            updatePollTimerLifecycle()
            return
        }

        restoreGeneration &+= 1
        let generation = restoreGeneration
        let scheduledKeys = Set(pendingRestorations.keys)
        let previousAttempt = lastRestorationAttemptKey
        let restoreWindow = restoreWindow
        let windowKeys = restorationWindowKeys
        let cancelledWrites = pendingRestorationDrains
        pendingRestorationDrains.removeAll()
        restoreTask = Task.detached { [weak self] in
            for task in cancelledWrites { await task.value }
            let snapshot: [WindowLiftAvoidance.WindowKey: ManagedFrames]? = await MainActor.run { [weak self] in
                guard let self, self.restoreGeneration == generation else { return nil }
                return self.pendingRestorations.filter { scheduledKeys.contains($0.key) }
            }
            guard let items = snapshot else { return }
            let keys = items.keys.sorted { ($0.pid, $0.cgWindowID) < ($1.pid, $1.cgWindowID) }
            let start = previousAttempt.flatMap { previous in
                keys.firstIndex { ($0.pid, $0.cgWindowID) > (previous.pid, previous.cgWindowID) }
            } ?? 0
            let rotatedKeys = Array(keys[start...]) + keys[..<start]
            let orderedKeys = newKeys.isEmpty ? rotatedKeys :
                rotatedKeys.filter { newKeys.contains($0) } + rotatedKeys.filter { !newKeys.contains($0) }
            let startTimes = items.compactMapValues { $0.processGeneration.map { timeval(tv_sec: Int($0.seconds), tv_usec: $0.microseconds) } }
            let budget = inheritedBudget ?? OperationReadBudget(maximumDuration: 2, cancellation: OperationCancellation())
            var remaining = items
            var lastAttemptedIndex: Int?
            for attempt in 0..<3 {
                guard !Task.isCancelled, !remaining.isEmpty, budget.canContinue else { break }
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                guard !Task.isCancelled, budget.canContinue else { break }
                if attempt > 0 {
                    let needsNewBatch = await MainActor.run { [weak self] in
                        guard let self, self.restoreGeneration == generation else { return true }
                        return !self.pendingRestorationDrains.isEmpty ||
                            self.pendingRestorations.keys.contains { items[$0] == nil }
                    }
                    if needsNewBatch { break }
                }
                let liveWindowKeys = await AsyncWorkScope.performBlocking(cancellation: budget.cancellation) {
                    budget.canContinue ? windowKeys() : nil
                }
                let attemptItems = orderedKeys.enumerated().compactMap { index, key in
                    remaining[key].map { (index, key, $0) }
                }
                await withTaskGroup(of: (Int, WindowLiftAvoidance.WindowKey, WindowRestorationOutcome?).self) { group in
                    var nextIndex = 0
                    func enqueueNext() {
                        guard !Task.isCancelled, budget.canContinue, nextIndex < attemptItems.count else { return }
                        let (index, key, frames) = attemptItems[nextIndex]
                        let batches = max(1, (attemptItems.count - nextIndex + 3) / 4)
                        let windowBudget = budget.limited(to: budget.remaining / Double(batches))
                        nextIndex += 1
                        group.addTask {
                            let outcome = await AsyncWorkScope.performBlocking(cancellation: budget.cancellation) {
                                guard windowBudget.canContinue else { return nil as WindowRestorationOutcome? }
                                return restoreWindow(key, frames, startTimes[key], liveWindowKeys ?? nil, windowBudget)
                            }
                            return (index, key, outcome ?? nil)
                        }
                    }
                    for _ in 0..<4 { enqueueNext() }
                    while let (index, key, outcome) = await group.next() {
                        if let outcome {
                            lastAttemptedIndex = max(lastAttemptedIndex ?? index, index)
                            if outcome == .handled {
                                remaining[key] = nil
                                await MainActor.run { [weak self] in
                                    guard let self, self.restoreGeneration == generation else { return }
                                    self.pendingRestorations.removeValue(forKey: key)
                                }
                            } else if case let .retryAfterPartialWrite(frame) = outcome, let planned = remaining[key] {
                                remaining[key]?.partiallyRestoredQuartz = frame
                                await MainActor.run { [weak self] in
                                    guard let self, self.pendingRestorations[key]?.hasSameRestorationPlan(as: planned) == true else { return }
                                    self.pendingRestorations[key]?.partiallyRestoredQuartz = frame
                                }
                            }
                        }
                        enqueueNext()
                    }
                }
            }
            let latestAttempted = lastAttemptedIndex.map { orderedKeys[$0] }
            await MainActor.run { [weak self] in
                guard let self, self.restoreGeneration == generation else { return }
                self.restoreTask = nil
                if self.pendingRestorations.isEmpty { self.lastRestorationAttemptKey = nil }
                else if let latestAttempted { self.lastRestorationAttemptKey = latestAttempted }
                self.releaseUnusedObservationWatermarks()
                self.nextRestoreRetryAt = self.uptime() + 5
                if !self.pendingRestorations.isEmpty {
                    #if DEBUG
                    self.logger.error("window restoration pending count=\(self.pendingRestorations.count, privacy: .public)")
                    #endif
                }
                let newKeys = Set(self.pendingRestorations.keys).subtracting(items.keys)
                if !self.pendingRestorationDrains.isEmpty || (budget.canContinue && !newKeys.isEmpty) {
                    self.launchRestoreTask(cancelledWrites: [], budget: budget, preferring: newKeys)
                    return
                }
                self.updatePollTimerLifecycle()
                self.updateTrackedProbeLifecycle()
                if self.isEnabled { self.poll() }
            }
        }
        updatePollTimerLifecycle()
    }

    private func store(
        _ state: WindowLiftAvoidance.SessionState,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        #if DEBUG
        let previous = states[key] ?? .idle
        #endif
        if state == .idle {
            states.removeValue(forKey: key)
            #if DEBUG
            lastTraceClassifications.removeValue(forKey: key)
            reportedClearanceLosses.removeValue(forKey: key)
            #endif
        } else {
            states[key] = state
        }
        #if DEBUG
        if traceEnabled, traceLabel(for: previous) != traceLabel(for: state) {
            let previousLabel = traceLabel(for: previous)
            let stateLabel = traceLabel(for: state)
            logger.info(
                "lift trace transition pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) from=\(previousLabel, privacy: .public) to=\(stateLabel, privacy: .public)"
            )
        }
        #endif
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    func clearManagedSession(
        for key: WindowLiftAvoidance.WindowKey,
        cancelWriter: Bool,
        reason: String,
        suppression: SuppressionRequest = .none
    ) {
        guard canMutateSessions() else {
            // 冻结期间只丢任务引用，会话数据一概不动。
            if let writer = writeTasks.removeValue(forKey: key) {
                if cancelWriter { writer.cancel() }
                pendingDrains.append(writer)
            }
            return
        }
        if cancelWriter, let writer = writeTasks.removeValue(forKey: key) {
            writer.cancel()
            retainCancelledWriter(writer, for: key)
        } else {
            writeTasks.removeValue(forKey: key)
        }
        observationWatermarks[key] = max(
            observationWatermarks[key] ?? 0,
            nextGeneration
        )
        pendingValidations.removeValue(forKey: key)
        let previous = states.removeValue(forKey: key)
        let frames = managedFrames.removeValue(forKey: key)
        switch (suppression, frames) {
        case let (.untilNative(userEra), frames?):
            suppressedFrames[key] = WindowLiftAvoidance.Suppression(
                nativeFrame: frames.nativeAppKit, targetFrame: frames.targetAppKit,
                origin: userEra ? .userChange : .untilNative
            )
        case let (.afterAppAnswer, frames?):
            suppressedFrames[key] = WindowLiftAvoidance.Suppression(
                nativeFrame: frames.nativeAppKit, targetFrame: frames.targetAppKit,
                origin: .applicationResponse(
                    standoffRounds: previous.map(Self.standoffRounds(of:)) ?? 0,
                    clearedAt: uptime()
                )
            )
        default:
            clearSuppression(for: key)
        }
        #if DEBUG
        lastTraceClassifications.removeValue(forKey: key)
        reportedClearanceLosses.removeValue(forKey: key)
        if traceEnabled, previous != nil {
            logger.info(
                "lift trace clear pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        #endif
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
        releaseUnusedObservationWatermarks()
    }

    private func releaseUnusedObservationWatermarks() {
        guard scanTask == nil, trackedProbeTask == nil,
              permissionDrainTask == nil,
              pendingDrains.isEmpty, pendingRestorationDrains.isEmpty else { return }
        let retained = Set(states.keys).union(suppressedFrames.keys).union(writeTasks.keys)
            .union(writeDrainTasks.keys).union(pendingRestorations.keys)
        observationWatermarks = observationWatermarks.filter { retained.contains($0.key) }
    }

    private func retainCancelledWriter(_ writer: Task<Void, Never>, for key: WindowLiftAvoidance.WindowKey) {
        let id = UUID()
        writeDrainTasks[key, default: [:]][id] = writer
        Task { @MainActor [weak self] in
            await writer.value
            guard let self else { return }
            self.writeDrainTasks[key]?.removeValue(forKey: id)
            if self.writeDrainTasks[key]?.isEmpty == true { self.writeDrainTasks.removeValue(forKey: key) }
            self.releaseUnusedObservationWatermarks()
        }
    }

    private func clearSuppression(for key: WindowLiftAvoidance.WindowKey) {
        suppressedFrames.removeValue(forKey: key)
        if states[key] == nil { sessionContexts.removeValue(forKey: key) }
    }

    private static func standoffRounds(of state: WindowLiftAvoidance.SessionState) -> Int {
        switch state {
        case .idle: return 0
        case let .writing(attempt): return attempt.standoffRounds
        case let .lifted(session): return session.standoffRounds
        case let .abandoned(session): return session.standoffRounds
        }
    }

    #if DEBUG
    private func reportDiagnostic(
        _ event: String, for key: WindowLiftAvoidance.WindowKey, generation: UInt64? = nil,
        cg: CGRect? = nil, ax: CGRect? = nil, frames snapshot: ManagedFrames? = nil,
        level: OSLogType = .default, detail: String
    ) {
        let app = NSRunningApplication(processIdentifier: key.pid)
        let frames = snapshot ?? managedFrames[key]
        let context = sessionContexts[key]
        let panelTop = context.map { String($0.primaryScreenHeight - $0.geometry.taskbarTop) } ?? "-"
        let message = """
            lift \(event) pid=\(key.pid) wid=\(key.cgWindowID) app=\(app?.bundleIdentifier ?? "-") \
            active=\(app.map { String($0.isActive) } ?? "-") generation=\(generation.map { String($0) } ?? "-") \
            cg=\(Self.diagnosticFrame(cg)) ax=\(Self.diagnosticFrame(ax)) native=\(Self.diagnosticFrame(frames?.nativeQuartz)) \
            target=\(Self.diagnosticFrame(frames?.targetQuartz)) visible=\(Self.diagnosticFrame(context?.visibleCGFrame)) \
            panelTopY=\(panelTop) \(detail)
            """
        if let diagnosticReporter { diagnosticReporter(message) }
        else { logger.log(level: level, "\(message, privacy: .public)") }
    }
    #endif

    #if DEBUG
    private static func diagnosticFrame(_ frame: CGRect?) -> String {
        guard let frame else { return "-" }
        return "[\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)]"
    }
    #endif

    #if DEBUG
    private func traceClassification(
        _ classification: WindowLiftAvoidance.FrameClassification,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        guard traceEnabled, lastTraceClassifications[key] != classification else { return }
        lastTraceClassifications[key] = classification
        logger.info(
            "lift trace classify pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: classification), privacy: .public)"
        )
    }
    #endif

    #if DEBUG
    private func traceLabel(for state: WindowLiftAvoidance.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case let .writing(attempt):
            return "writing(reliftCount:\(attempt.reliftCount))"
        case let .lifted(session):
            return "lifted(reliftCount:\(session.reliftCount))"
        case let .abandoned(session):
            return "abandoned(reason:\(session.reason.diagnosticDescription),reliftCount:\(session.reliftCount))"
        }
    }
    #endif
}
