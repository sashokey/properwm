import AppKit
import Combine
import CoreGraphics
import Foundation
#if DEBUG
import os
#endif

@MainActor
protocol DisplayTopologyUpdating: AnyObject {
    func updateDisplayTopology(_ table: WindowDisplayAttribution.Table)
}

#if DEBUG
@MainActor
final class DebugRuntimeState: ObservableObject {
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] = [:]

    func setFeedbackEntries(_ entries: [String: IntentFeedbackState.Entry]) {
        guard entries != feedbackEntriesByWindowID else { return }
        feedbackEntriesByWindowID = entries
    }


}
#endif

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    #if DEBUG
    let debugState = DebugRuntimeState()
    #endif
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:]
    private let tracker: any WindowInventoryTracking
    private let work = WindowActionQueue()
    private var actionTokens: [String: UUID] = [:]
    private var projectionInvalidationSubscriptions: [String: AnyCancellable] = [:]
    private let intentPipeline: IntentPipeline
    private let actionExecutor: any WindowActionExecuting
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?

    #if DEBUG
    private let chipProbeLogger = Logger(subsystem: "io.github.sashokey.properwm", category: "ChipProbe")
    private static let chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: ProcessInfo.processInfo.environment)
    #endif
    private static let handoffActiveGraceEnabled = DebugSwitch.handoffActiveGrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let handoffActivePredictionEnabled = DebugSwitch.handoffActivePrediction.isEnabled(in: ProcessInfo.processInfo.environment)

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        tracker: (any WindowInventoryTracking)? = nil,
        actionExecutor: any WindowActionExecuting = PlatformActionExecutor(),
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = {
            DisplayIdentity.attributionTable()
        },
        isAppFrontmost: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isActive == true }
    ) {
        self.intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner(isAppFrontmost: isAppFrontmost))
        self.tracker = tracker ?? AppTracker(inventoryLog: inventoryLog, displayTableProvider: displayTableProvider)
        self.actionExecutor = actionExecutor
    }

    func start() {
        guard snapshotSubscription == nil else { return }
        work.restart()
        let generation = work.generation
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
        projectionInvalidationSubscriptions.removeAll()
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        optimisticStatesByWindowID.removeAll()
        intentPipeline.reset()
        publishFeedbackEntries()
        snapshot = .empty
    }

    isolated deinit { stop() }

    func updateDisplayTopology(_ table: WindowDisplayAttribution.Table) {
        (tracker as? any DisplayTopologyUpdating)?.updateDisplayTopology(table)
    }

    func toggle(windowID: String) { trigger(.toggle(WindowID(rawValue: windowID))) }
    func activate(windowID: String) { trigger(.activate(WindowID(rawValue: windowID))) }
    func close(windowID: String) { trigger(.close(WindowID(rawValue: windowID))) }

    func trigger(_ intent: UserIntent, expected: WindowActionIdentity,
                 projectionInvalidations: AnyPublisher<Void, Never>,
                 isProjectionCurrent: @escaping @MainActor @Sendable () -> Bool) {
        guard snapshot.windows[intent.windowID]?.actionIdentity == expected, isProjectionCurrent() else { return }
        trigger(intent, projectionInvalidations: projectionInvalidations, isProjectionCurrent: isProjectionCurrent)
    }

    private func trigger(_ intent: UserIntent, projectionInvalidations: AnyPublisher<Void, Never>? = nil,
                         isProjectionCurrent: (@MainActor @Sendable () -> Bool)? = nil) {
        guard isRunning else { return }
        #if DEBUG
        HoverTrace.action("\(intent.action)", phase: "begin")
        defer { HoverTrace.action("\(intent.action)", phase: "dispatched") }
        #endif
        let key = intent.windowID.rawValue
        switch intent.action {
        case .close:
            guard !work.contains(key: key, kind: .closeWindow),
                  intentPipeline.canBegin(intent: intent) else { return }
        default:
            break
        }
        retireAction(for: key)
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: optimisticStatesByWindowID
        )

        #if DEBUG
        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            let optimisticStatus = optimisticStatesByWindowID[wid.rawValue]?.status.rawValue ?? "none"
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }
        #endif

        #if DEBUG
        if ClickLatencyTrace.isEnabled, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            ClickLatencyTrace.begin(
                windowID: wid,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }
        #endif

        let token = UUID()
        actionTokens[key] = token
        projectionInvalidationSubscriptions[key] = projectionInvalidations?.sink { [weak self] in
            guard let self, self.actionTokens[key] == token else { return }
            self.cancelAction(for: key)
        }
        let effectiveStatusAtPlan: WindowStatus? = request.windowID.flatMap { wid in
            optimisticStatesByWindowID[wid.rawValue]?.status ?? snapshot.windows[wid]?.status
        }
        applyOptimisticState(for: request, wasMinimizedAtPlan: effectiveStatusAtPlan == .minimized)
        intentPipeline.registerPending(intent: intent, request: request)
        publishFeedbackEntries()
        updateFeedbackTimer()

        dispatchToExecutor(intent: intent, request: request, forcedMinimizedPrior: effectiveStatusAtPlan == .minimized,
                           isProjectionCurrent: isProjectionCurrent)
    }

    private func dispatchToExecutor(intent: UserIntent, request: PlatformActionRequest, forcedMinimizedPrior: Bool,
                                    isProjectionCurrent: (@MainActor @Sendable () -> Bool)?) {
        let executor = actionExecutor
        let capturedSnapshot = snapshot
        let generation = work.generation
        let key = intent.windowID.rawValue
        guard let token = actionTokens[key] else { return }
        let onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?
        if (request.kind == .minimizeWindow || request.kind == .closeWindow) && Self.handoffActivePredictionEnabled {
            onHandoffActivePrediction = { @Sendable [weak self] (windowID: WindowID) in
                Task { @MainActor [weak self] in
                    guard let self, self.work.isCurrent(generation),
                          self.actionTokens[key] == token else { return }
                    guard self.optimisticStatesByWindowID[windowID.rawValue] == nil else { return }
                    guard let planned = capturedSnapshot.windows[windowID],
                          let current = self.snapshot.windows[windowID],
                          current.actionIdentity == planned.actionIdentity,
                          current.status != .minimized, current.status != .hidden else { return }
                    self.optimisticStatesByWindowID[windowID.rawValue] = OptimisticWindowState(
                        status: .active, createdAt: Date(), focusHandoffGrace: true,
                        systemPredicted: true, handoffSourceToken: token
                    )
                }
            }
        } else {
            onHandoffActivePrediction = nil
        }
        let accepted = work.submit(key: key, kind: request.kind,
            maximumPendingKeys: max(32, capturedSnapshot.windows.count)) { [weak self] generation, cancellation in
            if let isProjectionCurrent {
                let admitted = await MainActor.run { [weak self] in
                    guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                          self.actionTokens[key] == token else { return false }
                    if isProjectionCurrent() { return true }
                    self.cancelAction(for: key)
                    return false
                }
                guard admitted else { return }
            }
            #if DEBUG
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "execStart")
            #endif
            let result = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                executor.execute(request, snapshot: capturedSnapshot,
                                 forcedMinimizedPrior: forcedMinimizedPrior,
                                 cancellation: cancellation,
                                 onHandoffActivePrediction: onHandoffActivePrediction)
            }
            guard let success = result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                      self.actionTokens[key] == token else { return }
                #if DEBUG
                ClickLatencyTrace.end(windowID: request.windowID?.rawValue, success: success)
                #endif
                self.retireAction(for: key, preservingHandoff: success)
                if !success { self.optimisticStatesByWindowID.removeValue(forKey: key) }
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.publishFeedbackEntries()
                self.updateFeedbackTimer()
            }
        }
        if !accepted {
            retireAction(for: key)
            optimisticStatesByWindowID.removeValue(forKey: key)
            intentPipeline.registerExecutionResult(intent: intent, request: request, success: false)
            publishFeedbackEntries()
            updateFeedbackTimer()
        }
    }

    private func cancelAction(for key: String) {
        work.cancel(key: key)
        #if DEBUG
        ClickLatencyTrace.end(windowID: key, success: false)
        #endif
        retireAction(for: key)
        optimisticStatesByWindowID.removeValue(forKey: key)
        intentPipeline.discardFeedback(for: [key])
        publishFeedbackEntries()
        updateFeedbackTimer()
    }

    private func retireAction(for key: String, preservingHandoff: Bool = false) {
        projectionInvalidationSubscriptions.removeValue(forKey: key)
        guard let token = actionTokens.removeValue(forKey: key), !preservingHandoff else { return }
        let retainedStates = optimisticStatesByWindowID.filter { $0.value.handoffSourceToken != token }
        if retainedStates.count != optimisticStatesByWindowID.count {
            optimisticStatesByWindowID = retainedStates
        }
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        var retainedActionIDs = Set<String>()
        var replacedIDs = Set<String>()
        for (id, window) in newSnapshot.windows {
            if let previous = snapshot.windows[id], previous.actionIdentity != window.actionIdentity {
                replacedIDs.insert(id.rawValue)
            } else {
                retainedActionIDs.insert(id.rawValue)
            }
        }
        for key in actionTokens.keys where !retainedActionIDs.contains(key) {
            let closed = !replacedIDs.contains(key) && work.contains(key: key, kind: .closeWindow)
            retireAction(for: key, preservingHandoff: closed)
        }
        work.retain(windowIDs: retainedActionIDs)
        if !replacedIDs.isEmpty {
            intentPipeline.discardFeedback(for: replacedIDs)
            let retainedStates = optimisticStatesByWindowID.filter { !replacedIDs.contains($0.key) }
            if retainedStates != optimisticStatesByWindowID {
                optimisticStatesByWindowID = retainedStates
            }
        }
        if snapshot != newSnapshot { snapshot = newSnapshot }
        intentPipeline.reconcile(with: newSnapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        updateFeedbackTimer()

    }

    private func tickFeedback() {
        guard isRunning else { return }
        intentPipeline.reconcile(with: snapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        updateFeedbackTimer()
    }

    private func publishFeedbackEntries() {
        #if DEBUG
        let next = intentPipeline.feedbackState.entriesByWindowID
        debugState.setFeedbackEntries(next)
        #endif
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
            #if DEBUG
            if Self.chipProbeEnabled, let cleared {
                chipProbeLogger.info("optimistic-cleared windowID=\(windowID, privacy: .public) predicted=\(state.status.rawValue, privacy: .public) ageMs=\(Int(now.timeIntervalSince(state.createdAt) * 1000), privacy: .public) reason=\(cleared, privacy: .public)")
            }
            #endif
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
