import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class DebugRuntimeState: ObservableObject {
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] = [:]
    @Published private(set) var observationStatusText: String = "正在启动"

    func setFeedbackEntries(_ entries: [String: IntentFeedbackState.Entry]) {
        guard entries != feedbackEntriesByWindowID else { return }
        feedbackEntriesByWindowID = entries
    }

    func setObservationStatusText(_ text: String) {
        guard text != observationStatusText else { return }
        observationStatusText = text
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    @Published private(set) var hasRequiredPermissions: Bool = false
    let debugState: DebugRuntimeState
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:]
    @Published private(set) var heldLabelTitlesByChipID: [String: String] = [:]
    private var titleSettle = WindowTitleSettle()
    private var titleSettleTimer: Timer?
    private let titleSettleEnabled = DebugSwitch.titleSettle.isEnabled(in: ProcessInfo.processInfo.environment)
    private let tracker: any WindowInventoryTracking
    private let work = AsyncWorkScope()
    private var actionTokens: [String: UUID] = [:]
    private let intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner())
    private let actionExecutor: any WindowActionExecuting
    private let isAccessibilityTrusted: () -> Bool
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?
    private var startedAt: Date?

    private let chipProbeLogger = Logger(subsystem: "io.github.sashokey.properwm", category: "ChipProbe")
    private static let chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let settleGateEnabled = DebugSwitch.minimizeSettleGate.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let handoffActiveGraceEnabled = DebugSwitch.handoffActiveGrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let handoffActivePredictionEnabled = DebugSwitch.handoffActivePrediction.isEnabled(in: ProcessInfo.processInfo.environment)

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        debugState: DebugRuntimeState? = nil,
        tracker: (any WindowInventoryTracking)? = nil,
        actionExecutor: any WindowActionExecuting = PlatformActionExecutor(),
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = {
            DisplayIdentity.attributionTable()
        },
        isAccessibilityTrusted: @escaping () -> Bool = { PermissionService().hasRequiredPermissions() }
    ) {
        self.tracker = tracker ?? AppTracker(inventoryLog: inventoryLog, displayTableProvider: displayTableProvider)
        self.actionExecutor = actionExecutor
        self.debugState = debugState ?? DebugRuntimeState()
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func start() {
        guard snapshotSubscription == nil else { return }
        work.restart()
        let generation = work.generation
        startedAt = Date()
        hasRequiredPermissions = isAccessibilityTrusted()
        snapshotSubscription = tracker.snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSnapshot in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleSnapshotUpdate(newSnapshot)
            }
        tracker.start()
        updateFeedbackTimer()
    }

    private var isRunning: Bool { snapshotSubscription != nil }

    func stop() {
        work.stop()
        actionTokens.removeAll()
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        titleSettleTimer?.invalidate()
        titleSettleTimer = nil
        for held in heldActionsByWindowID.values { held.workItem.cancel() }
        heldActionsByWindowID.removeAll()
        recentMinimizeDispatchAtByWindowID.removeAll()
        optimisticStatesByWindowID.removeAll()
        heldLabelTitlesByChipID.removeAll()
        titleSettle = WindowTitleSettle()
        intentPipeline.reset()
        publishFeedbackEntries()
        snapshot = .empty
        startedAt = nil
    }

    isolated deinit { stop() }

    func toggle(windowID: String) { trigger(.toggle(WindowID(rawValue: windowID))) }
    func activate(windowID: String) { trigger(.activate(WindowID(rawValue: windowID))) }
    func minimize(windowID: String) { trigger(.minimize(WindowID(rawValue: windowID))) }

    func close(windowID: String) { trigger(.close(WindowID(rawValue: windowID))) }

    private func trigger(_ intent: UserIntent) {
        guard isRunning else { return }
        HoverTrace.action("\(intent.action)", phase: "begin")
        defer { HoverTrace.action("\(intent.action)", phase: "dispatched") }
        cancelHeldAction(for: intent)
        switch intent.action {
        case .close:
            guard intentPipeline.canBegin(intent: intent) else { return }
        default:
            break
        }
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: optimisticStatesByWindowID
        )

        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            let optimisticStatus = optimisticStatesByWindowID[wid.rawValue]?.status.rawValue ?? "none"
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }

        if ClickLatencyTrace.isEnabled, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            ClickLatencyTrace.begin(
                windowID: wid,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }

        actionTokens[intent.windowID.rawValue] = UUID()
        let effectiveStatusAtPlan: WindowStatus? = request.windowID.flatMap { wid in
            optimisticStatesByWindowID[wid.rawValue]?.status ?? snapshot.windows[wid]?.status
        }
        applyOptimisticState(for: request, wasMinimizedAtPlan: effectiveStatusAtPlan == .minimized)
        intentPipeline.registerPending(intent: intent, request: request)
        publishFeedbackEntries()
        updateFeedbackTimer()

        routeThroughSettleGate(intent: intent, request: request)
    }

    private struct HeldAction {
        let intent: UserIntent
        let request: PlatformActionRequest
        let anchor: Date
        let generation: UInt64
        var workItem: DispatchWorkItem
    }

    private var recentMinimizeDispatchAtByWindowID: [String: Date] = [:]
    private var heldActionsByWindowID: [String: HeldAction] = [:]
    private var settleGateGeneration: UInt64 = 0

    private func routeThroughSettleGate(intent: UserIntent, request: PlatformActionRequest) {
        guard Self.settleGateEnabled, let windowID = request.windowID?.rawValue else {
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        if request.kind == .minimizeWindow {
            if !windowID.hasPrefix("app-") {
                recentMinimizeDispatchAtByWindowID[windowID] = Date()
            }
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        let verdict = MinimizeSettleGate.verdict(
            requestKind: request.kind,
            minimizeDispatchedAt: recentMinimizeDispatchAtByWindowID[windowID],
            snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
            now: Date()
        )
        switch verdict {
        case .dispatchNow:
            dispatchToExecutor(intent: intent, request: request)
        case .hold(let until):
            ClickLatencyTrace.mark(windowID: windowID, "settleGate", detail: "hold")
            holdAction(intent: intent, request: request, windowID: windowID, until: until)
        }
    }

    private func holdAction(intent: UserIntent, request: PlatformActionRequest, windowID: String, until: Date) {
        guard let anchor = recentMinimizeDispatchAtByWindowID[windowID] else {
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        settleGateGeneration &+= 1
        let generation = settleGateGeneration
        let workItem = makeFlushWorkItem(windowID: windowID, generation: generation)
        heldActionsByWindowID[windowID] = HeldAction(
            intent: intent, request: request, anchor: anchor, generation: generation, workItem: workItem
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: workItem)
    }

    private func makeFlushWorkItem(windowID: String, generation: UInt64) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushHeldAction(windowID: windowID, generation: generation)
            }
        }
    }

    private func flushHeldAction(windowID: String, generation: UInt64) {
        guard isRunning,
              let held = heldActionsByWindowID[windowID],
              held.generation == generation else { return }
        let verdict = MinimizeSettleGate.verdict(
            requestKind: held.request.kind,
            minimizeDispatchedAt: held.anchor,
            snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
            now: Date()
        )
        switch verdict {
        case .dispatchNow:
            heldActionsByWindowID.removeValue(forKey: windowID)
            let confirmed = snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized
            ClickLatencyTrace.mark(windowID: windowID, "settleGateFlush", detail: confirmed ? "confirmed" : "cap")
            dispatchToExecutor(intent: held.intent, request: held.request)
        case .hold(let until):
            held.workItem.cancel()
            let workItem = makeFlushWorkItem(windowID: windowID, generation: generation)
            heldActionsByWindowID[windowID]?.workItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: workItem)
        }
    }

    private func reevaluateHeldActions(now: Date = Date()) {
        if !recentMinimizeDispatchAtByWindowID.isEmpty {
            recentMinimizeDispatchAtByWindowID = recentMinimizeDispatchAtByWindowID.filter {
                now.timeIntervalSince($0.value) < MinimizeSettleGate.priorWindow
            }
        }
        guard !heldActionsByWindowID.isEmpty else { return }
        for (windowID, held) in heldActionsByWindowID {
            let verdict = MinimizeSettleGate.verdict(
                requestKind: held.request.kind,
                minimizeDispatchedAt: held.anchor,
                snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
                now: now
            )
            guard case .dispatchNow = verdict else { continue }
            held.workItem.cancel()
            heldActionsByWindowID.removeValue(forKey: windowID)
            let confirmed = snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized
            ClickLatencyTrace.mark(windowID: windowID, "settleGateFlush", detail: confirmed ? "confirmed" : "cap")
            dispatchToExecutor(intent: held.intent, request: held.request)
        }
    }

    private func cancelHeldAction(for intent: UserIntent) {
        guard let held = heldActionsByWindowID.removeValue(forKey: intent.windowID.rawValue) else { return }
        held.workItem.cancel()
        switch intent.action {
        case .close:
            intentPipeline.registerExecutionResult(intent: held.intent, request: held.request, success: false)
        default:
            break
        }
    }

    private func dispatchToExecutor(intent: UserIntent, request: PlatformActionRequest) {
        let executor = actionExecutor
        let capturedSnapshot = snapshot
        let generation = work.generation
        let key = intent.windowID.rawValue
        guard let token = actionTokens[key] else { return }
        let forcedMinimizedPrior = request.kind == .activateWindow
            && MinimizeSettleGate.dispatchPrior(
                minimizeDispatchedAt: request.windowID.flatMap { recentMinimizeDispatchAtByWindowID[$0.rawValue] },
                now: Date()
            )
        let onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?
        if (request.kind == .minimizeWindow || request.kind == .closeWindow) && Self.handoffActivePredictionEnabled {
            onHandoffActivePrediction = { @Sendable [weak self] (windowID: WindowID) in
                Task { @MainActor [weak self] in
                    guard let self, self.work.isCurrent(generation),
                          self.actionTokens[key] == token else { return }
                    guard self.optimisticStatesByWindowID[windowID.rawValue] == nil else { return }
                    guard let current = self.snapshot.windows[windowID],
                          current.status != .minimized, current.status != .hidden else { return }
                    self.optimisticStatesByWindowID[windowID.rawValue] = OptimisticWindowState(
                        status: .active, createdAt: Date(), focusHandoffGrace: true, systemPredicted: true
                    )
                }
            }
        } else {
            onHandoffActivePrediction = nil
        }
        work.launch(priority: .userInitiated) { [weak self] generation in
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "execStart")
            let result = await AsyncWorkScope.performBlocking {
                executor.execute(request, snapshot: capturedSnapshot,
                                 forcedMinimizedPrior: forcedMinimizedPrior,
                                 onHandoffActivePrediction: onHandoffActivePrediction)
            }
            ClickLatencyTrace.end(windowID: request.windowID?.rawValue, success: result == true)
            guard let success = result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation),
                      self.actionTokens[key] == token else { return }
                self.actionTokens.removeValue(forKey: key)
                if !success { self.optimisticStatesByWindowID.removeValue(forKey: key) }
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.publishFeedbackEntries()
                self.updateFeedbackTimer()
            }
        }
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        if snapshot != newSnapshot { snapshot = newSnapshot }
        reconcileTitleSettle(with: newSnapshot)
        let trusted = isAccessibilityTrusted()
        if hasRequiredPermissions != trusted { hasRequiredPermissions = trusted }
        intentPipeline.reconcile(with: newSnapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        reevaluateHeldActions()
        updateFeedbackTimer()
        if let startedAt {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugState.setObservationStatusText(hasRequiredPermissions ? "实时 \(ms)ms" : "仅窗口列表")
            self.startedAt = nil
        }
    }

    private func reconcileTitleSettle(with newSnapshot: DockSnapshot) {
        guard titleSettleEnabled else { return }
        var rawTitles: [String: String] = [:]
        for item in StripItem.items(from: newSnapshot) where !item.isAppLevelFallback {
            rawTitles[item.id] = item.title
        }
        let now = ProcessInfo.processInfo.systemUptime
        let held = titleSettle.observe(rawTitles: rawTitles, now: now)
        if held != heldLabelTitlesByChipID { heldLabelTitlesByChipID = held }

        titleSettleTimer?.invalidate()
        titleSettleTimer = nil
        guard let releaseAt = titleSettle.nextReleaseAt else { return }
        let delay = max(0.05, releaseAt - now + 0.05)
        titleSettleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.reconcileTitleSettle(with: self.snapshot)
            }
        }
    }

    private func tickFeedback() {
        guard isRunning else { return }
        intentPipeline.reconcile(with: snapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        reevaluateHeldActions()
        updateFeedbackTimer()
    }

    private func publishFeedbackEntries() {
        let next = intentPipeline.feedbackState.entriesByWindowID
        debugState.setFeedbackEntries(next)
    }

    private func updateFeedbackTimer() {
        let shouldTick = FeedbackTickPolicy.shouldTick(
            isRunning: isRunning,
            hasFeedbackEntries: !intentPipeline.feedbackState.entriesByWindowID.isEmpty,
            hasOptimisticStates: !optimisticStatesByWindowID.isEmpty
        )
        guard shouldTick else {
            feedbackTimer?.invalidate()
            feedbackTimer = nil
            return
        }
        guard feedbackTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFeedback() }
        }
        timer.tolerance = 0.05
        feedbackTimer = timer
    }

    #if DEBUG
    var pendingActionsForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    private static let optimisticTimeout: TimeInterval = 4.0

    private func applyOptimisticState(for request: PlatformActionRequest, wasMinimizedAtPlan: Bool) {
        let state: OptimisticWindowState?
        switch request.kind {
        case .activateWindow:
            state = OptimisticWindowState(status: .active, createdAt: Date(), focusHandoffGrace: wasMinimizedAtPlan)
        case .minimizeWindow:
            state = OptimisticWindowState(status: .minimized, createdAt: Date())
        case .closeWindow:
            state = nil
        }
        guard let state, let windowID = request.windowID else { return }
        optimisticStatesByWindowID[windowID.rawValue] = state
    }

    private func reconcileOptimisticStates(now: Date = Date()) {
        guard !optimisticStatesByWindowID.isEmpty else { return }
        let next = optimisticStatesByWindowID.filter { windowID, state in
            let cleared: String?
            if now.timeIntervalSince(state.createdAt) > Self.optimisticTimeout {
                cleared = "timeout"
            } else if snapshot.windows[WindowID(rawValue: windowID)] == nil {
                cleared = "window-gone"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      Self.optimisticConfirmed(predicted: state.status, actual: record.status) {
                cleared = "confirmed"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      OptimisticWindowState.systemPredictionFalsified(state: state, actual: record.status) {
                cleared = "prediction-falsified"
            } else if OptimisticWindowState.supersededByActiveSibling(
                windowID: windowID, state: state, now: now,
                optimisticStates: optimisticStatesByWindowID,
                snapshot: snapshot, handoffGraceEnabled: Self.handoffActiveGraceEnabled
            ) {
                cleared = "superseded-by-active-sibling"
            } else {
                cleared = nil
            }
            if Self.chipProbeEnabled, let cleared {
                chipProbeLogger.info("optimistic-cleared windowID=\(windowID, privacy: .public) predicted=\(state.status.rawValue, privacy: .public) ageMs=\(Int(now.timeIntervalSince(state.createdAt) * 1000), privacy: .public) reason=\(cleared, privacy: .public)")
            }
            return cleared == nil
        }
        if next != optimisticStatesByWindowID {
            optimisticStatesByWindowID = next
        }
    }

    private static func optimisticConfirmed(predicted: WindowStatus, actual: WindowStatus) -> Bool {
        if predicted == actual { return true }
        if (predicted == .minimized || predicted == .hidden) && actual == .disappeared { return true }
        return false
    }
}
