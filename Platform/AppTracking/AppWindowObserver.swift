import ApplicationServices
import Foundation
import Synchronization

@MainActor
final class AppWindowObserver {
    typealias Factory = @Sendable (pid_t, @escaping @Sendable (AXElementKey, String) -> Void) -> (any WindowObservationSession)?
    let pid: pid_t
    private var session: (any WindowObservationSession)?
    private struct CleanupRequest: Sendable {
        let element: AXElementKey
        var items = WindowSubscriptionItem.allCases
        var retriesRemaining = 2
        var queued = true
    }

    private final class CleanupSession: Sendable {
        let session: any WindowObservationSession
        let cancellation = OperationCancellation()
        let pending = Mutex<[UUID: CleanupRequest]>([:])

        init(session: any WindowObservationSession) { self.session = session }

        func stop() {
            cancellation.cancel()
            pending.withLock { $0.removeAll() }
        }
    }
    private var cleanupSession: CleanupSession?
    private let makeSession: Factory
    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.window-subscriptions", qos: .utility)
    private let work = AsyncWorkScope()
    private var isRunning = false
    private var isStarting = false
    private var applicationItems: [String: WindowSubscriptionItemState] = [:]
    private var applicationRetryAt: TimeInterval = 0
    private var applicationRetryStep = 0
    private var waitingWindows: [CGWindowID: AXElementKey] = [:]
    private struct RegistrationWork {
        let id = UUID()
        let cancellation = OperationCancellation()
    }
    private var inFlight: [AXElementKey: RegistrationWork] = [:]
    private var subscriptions = WindowSubscriptionLedger<AXElementKey>(instanceIDs: AppWindowObserver.instanceIDs)
    private static let instanceIDs = WindowSubscriptionInstanceIDs()
    private let clock: @Sendable () -> TimeInterval

    var isActive: Bool {
        session != nil && Self.applicationNotifications.allSatisfy { applicationItems[$0] == .done }
    }
    var onWindowCreated: ((pid_t) -> Void)?
    var onWindowDestroyed: ((pid_t, CGWindowID, AXUIElement) -> Void)?
    var onWindowMinimized: ((pid_t, CGWindowID) -> Void)?
    var onWindowDeminiaturized: ((pid_t, CGWindowID) -> Void)?
    var onFocusedWindowChanged: ((pid_t) -> Void)?
    var onTitleChanged: ((pid_t, CGWindowID) -> Void)?
    #if DEBUG
    var onSubscriptionDestroyNotified: ((pid_t, CGWindowID, UInt64?) -> Void)?
    var onSubscriptionAttempt: ((WindowSubscriptionAttemptReport) -> Void)?
    #endif

    enum Registration {
        case none
        case scheduled
        case retryDue(WindowSubscriptionRetryCandidate<AXElementKey>)
    }

    nonisolated static let retryTimeLimit: TimeInterval = 0.05
    private static let applicationNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification
    ]
    #if DEBUG
    private static let dropsDestroyNotifications = DebugSwitch.simulateNoDestroy.isEnabled()
    #endif

    init(pid: pid_t, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeSession: @escaping Factory = { AXWindowObservationSession(pid: $0, receive: $1) }) {
        self.pid = pid
        self.clock = clock
        self.makeSession = makeSession
    }

    isolated deinit { stop() }

    private struct ApplicationAttemptResult: Sendable {
        let session: (any WindowObservationSession)?
        let results: [String: AXError]
    }

    func start() {
        if !isRunning {
            isRunning = true
            work.restart()
        }
        retryPendingRemovals()
        guard !isStarting, clock() >= applicationRetryAt else { return }
        let notifications = Self.applicationNotifications.filter {
            applicationItems[$0] != .done && applicationItems[$0] != .unsupported
        }
        guard session == nil || !notifications.isEmpty else { return }
        isStarting = true
        let currentSession = session
        let makeSession = makeSession
        let pid = pid
        let queue = queue
        let generation = work.generation
        let receive: @Sendable (AXElementKey, String) -> Void = { [weak self] element, name in
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleNotification(element: element.e, notification: name)
            }
        }
        let cancellation = OperationCancellation()
        work.launch { [weak self] generation in
            let created = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                let session = currentSession ?? makeSession(pid, receive)
                var results: [String: AXError] = [:]
                for notification in notifications {
                    guard !cancellation.isCancelled else { break }
                    if let session { results[notification] = session.add(notification, element: nil) }
                }
                return ApplicationAttemptResult(session: session, results: results)
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.isStarting = false
                guard let created else { return }
                for (notification, result) in created.results {
                    switch result {
                    case .success, .notificationAlreadyRegistered: self.applicationItems[notification] = .done
                    case .notificationUnsupported: self.applicationItems[notification] = .unsupported
                    default: self.applicationItems[notification] = .failed
                    }
                }
                if let session = created.session, self.session == nil {
                    self.session = session
                    self.cleanupSession = CleanupSession(session: session)
                    session.attach()
                    let windows = self.waitingWindows
                    self.waitingWindows.removeAll()
                    for (id, key) in windows { _ = self.registerWindow(key.e, cgWindowID: id) }
                }
                let needsRetry = self.session == nil || Self.applicationNotifications.contains {
                    self.applicationItems[$0] != .done && self.applicationItems[$0] != .unsupported
                }
                if needsRetry {
                    let delays = WindowSubscriptionLedger<AXElementKey>.backoff
                    self.applicationRetryAt = self.clock() + delays[min(self.applicationRetryStep, delays.count - 1)]
                    self.applicationRetryStep = min(self.applicationRetryStep + 1, delays.count - 1)
                } else {
                    self.applicationRetryAt = 0
                    self.applicationRetryStep = 0
                }
            }
        }
    }

    func stop() {
        for registration in inFlight.values { registration.cancellation.cancel() }
        work.stop()
        cleanupSession?.stop()
        cleanupSession = nil
        session?.detach()
        session = nil
        isRunning = false
        isStarting = false
        applicationItems.removeAll()
        applicationRetryAt = 0
        applicationRetryStep = 0
        waitingWindows.removeAll()
        inFlight.removeAll()
        subscriptions.removeAll()
    }

    func registerWindow(_ element: AXUIElement, cgWindowID: CGWindowID) -> Registration {
        let key = AXElementKey(e: element)
        guard session != nil else {
            if isRunning {
                if let previousID = waitingWindows.first(where: { $0.value == key })?.key {
                    waitingWindows.removeValue(forKey: previousID)
                }
                waitingWindows[cgWindowID] = key
            }
            return .none
        }
        if let replaced = subscriptions.rebind(element: key, to: cgWindowID) { retire(replaced.element) }
        guard inFlight[key] == nil else { return .none }
        let now = clock()
        guard let kind = subscriptions.attemptKind(cgWindowID: cgWindowID, element: key, now: now) else { return .none }
        if kind == .retry {
            return .retryDue(WindowSubscriptionRetryCandidate(pid: pid, cgWindowID: cgWindowID, element: key,
                                                               retryAt: subscriptions.record(for: cgWindowID)?.retryAt ?? now))
        }
        schedule(key: key, cgWindowID: cgWindowID, kind: kind)
        return .scheduled
    }

    func isRetryValid(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>) -> Bool {
        guard session != nil, inFlight[candidate.element] == nil, candidate.pid == pid else { return false }
        return subscriptions.attemptKind(cgWindowID: candidate.cgWindowID, element: candidate.element, now: clock()) == .retry
    }

    func performRetry(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>,
                      completion: (@MainActor @Sendable (WindowSubscriptionAttemptReport) -> Void)? = nil) {
        guard isRetryValid(candidate) else { return }
        schedule(key: candidate.element, cgWindowID: candidate.cgWindowID, kind: .retry, completion: completion)
    }

    func isCovered(cgWindowID: CGWindowID) -> Bool { subscriptions.isCovered(cgWindowID: cgWindowID) }

    func subscribedElement(cgWindowID: CGWindowID) -> (element: AXUIElement, instanceID: UInt64)? {
        subscriptions.record(for: cgWindowID).map { ($0.element.e, $0.instanceID) }
    }

    func retainSubscriptions(keep: Set<CGWindowID>) -> [(cgWindowID: CGWindowID, instanceID: UInt64)] {
        waitingWindows = waitingWindows.filter { keep.contains($0.key) }
        for (id, record) in subscriptions.records where !keep.contains(id) {
            retire(record.element)
        }
        return subscriptions.retain(keep: keep)
    }

    private func retire(_ key: AXElementKey) {
        inFlight.removeValue(forKey: key)?.cancellation.cancel()
        guard let cleanupSession else { return }
        let id = UUID()
        cleanupSession.pending.withLock { $0[id] = CleanupRequest(element: key) }
        enqueueRemoval(id, session: cleanupSession)
    }

    private func retryPendingRemovals() {
        guard let cleanupSession else { return }
        let retries = cleanupSession.pending.withLock { pending in
            let ids = Array(pending.lazy.filter { !$0.value.queued }.prefix(4)).map(\.key)
            for id in ids {
                pending[id]?.queued = true
                pending[id]?.retriesRemaining -= 1
            }
            return ids
        }
        for id in retries { enqueueRemoval(id, session: cleanupSession) }
    }

    private func enqueueRemoval(_ id: UUID, session cleanupSession: CleanupSession) {
        queue.async { [weak cleanupSession] in
            guard let cleanupSession, !cleanupSession.cancellation.isCancelled,
                  var request = cleanupSession.pending.withLock({ $0[id] }) else { return }
            var failed: [WindowSubscriptionItem] = []
            for item in request.items {
                guard !cleanupSession.cancellation.isCancelled,
                      cleanupSession.pending.withLock({ $0[id] != nil }) else { return }
                let result = cleanupSession.session.remove(item.notificationName, element: request.element)
                if result == .cannotComplete || result == .failure { failed.append(item) }
            }
            cleanupSession.pending.withLock { pending in
                guard pending[id] != nil else { return }
                let retryCount = pending.values.lazy.filter { !$0.queued }.prefix(32).count
                if failed.isEmpty || request.retriesRemaining == 0 || retryCount == 32 {
                    pending.removeValue(forKey: id)
                } else {
                    request.items = failed
                    request.queued = false
                    pending[id] = request
                }
            }
        }
    }

    private struct AttemptResult: Sendable {
        let results: [WindowSubscriptionItem: AXError]
        let sawFailure: Bool
        #if DEBUG
        let stop: WindowSubscriptionStop
        let duration: TimeInterval
        #endif
    }

    private func schedule(key: AXElementKey, cgWindowID: CGWindowID, kind: WindowSubscriptionAttemptKind,
                          completion: (@MainActor @Sendable (WindowSubscriptionAttemptReport) -> Void)? = nil) {
        guard let session else { return }
        if let old = subscriptions.record(for: cgWindowID), old.element != key { retire(old.element) }
        cleanupSession?.pending.withLock { $0 = $0.filter { $0.value.element != key } }
        let begun = subscriptions.beginAttempt(cgWindowID: cgWindowID, element: key, kind: kind, now: clock())
        let registration = RegistrationWork()
        let token = registration.id
        inFlight[key] = registration
        let queue = queue
        let clock = clock
        #if DEBUG
        let finish: @MainActor @Sendable (WindowSubscriptionAttemptReport) -> Void = completion ?? { [weak self] in self?.onSubscriptionAttempt?($0) }
        #endif
        let cancellation = registration.cancellation
        work.launch { [weak self] generation in
            let result = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                let start = clock()
                var results: [WindowSubscriptionItem: AXError] = [:]
                var sawTimeout = false
                var sawFailure = false
                #if DEBUG
                var stop: WindowSubscriptionStop = .completed
                #endif
                attempt: for (index, item) in begun.items.enumerated() {
                    guard !cancellation.isCancelled else { break }
                    switch WindowSubscriptionAttemptPolicy.step(item: item, index: index, sawTimeout: sawTimeout,
                        elapsed: clock() - start, timeLimit: kind == .retry ? Self.retryTimeLimit : nil) {
                    case .send: break
                    case .skip: continue attempt
                    #if DEBUG
                    case .stop(let reason):
                        if let reason { stop = reason }
                        break attempt
                    #else
                    case .stop: break attempt
                    #endif
                    }
                    let result = session.add(item.notificationName, element: key)
                    results[item] = result
                    if result == .invalidUIElement {
                        #if DEBUG
                        stop = .dead
                        #endif
                        break
                    }
                    if result == .cannotComplete { sawTimeout = true }
                    switch result {
                    case .success, .notificationAlreadyRegistered, .notificationUnsupported: break
                    default: sawFailure = true
                    }
                }
                #if DEBUG
                if stop == .completed, sawTimeout { stop = .timeoutSkippedRest }
                return AttemptResult(results: results, sawFailure: sawFailure, stop: stop, duration: clock() - start)
                #else
                return AttemptResult(results: results, sawFailure: sawFailure)
                #endif
            }
            guard let result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.inFlight[key]?.id == token,
                      let cgWindowID = self.subscriptions.cgWindowID(forElement: key),
                      self.subscriptions.record(for: cgWindowID)?.instanceID == begun.instanceID else { return }
                self.inFlight[key] = nil
                for (item, error) in result.results { self.subscriptions.record(cgWindowID: cgWindowID, item: item, result: error) }
                self.subscriptions.finishAttempt(cgWindowID: cgWindowID, now: clock(), sawFailure: result.sawFailure)
                #if DEBUG
                finish(WindowSubscriptionAttemptReport(pid: self.pid, cgWindowID: cgWindowID, kind: kind,
                    instanceID: begun.instanceID, previousInstanceID: begun.previousInstanceID, results: result.results,
                    stop: result.stop, covered: self.subscriptions.isCovered(cgWindowID: cgWindowID), durationMs: result.duration * 1_000))
                #endif
            }
        }
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    fileprivate func handleNotification(element: AXUIElement, notification notifStr: String) {
        if notifStr == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(pid)
        } else if notifStr == (kAXFocusedWindowChangedNotification as String)
                    || notifStr == (kAXMainWindowChangedNotification as String) {
            onFocusedWindowChanged?(pid)
        } else if notifStr == (kAXUIElementDestroyedNotification as String) {
            #if DEBUG
            if Self.dropsDestroyNotifications { return }
            #endif
            // A destroyed element can no longer resolve its window id (`_AXUIElementGetWindow`
            // fails), so the subscription ledger is the lookup.
            let key = AXElementKey(e: element)
            if let hit = subscriptions.noteDestroyed(element: key) {
                if hit.removedInstanceID != nil {
                    inFlight.removeValue(forKey: key)?.cancellation.cancel()
                }
                #if DEBUG
                onSubscriptionDestroyNotified?(pid, hit.cgWindowID, hit.removedInstanceID)
                #endif
                if hit.removedInstanceID != nil { onWindowDestroyed?(pid, hit.cgWindowID, element) }
            }
        } else if notifStr == (kAXWindowMiniaturizedNotification as String) {
            if let cgID = subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onWindowMinimized?(pid, cgID)
            }
        } else if notifStr == (kAXWindowDeminiaturizedNotification as String) {
            if let cgID = subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onWindowDeminiaturized?(pid, cgID)
            }
        } else if notifStr == (kAXTitleChangedNotification as String) {
            if let cgID = subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onTitleChanged?(pid, cgID)
            }
        }
    }
}

#if DEBUG
struct WindowSubscriptionAttemptReport {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let kind: WindowSubscriptionAttemptKind
    let instanceID: UInt64
    let previousInstanceID: UInt64?
    let results: [WindowSubscriptionItem: AXError]
    let stop: WindowSubscriptionStop
    let covered: Bool
    let durationMs: Double
}
#else
struct WindowSubscriptionAttemptReport {}
#endif

extension WindowSubscriptionItem {
    var notificationName: String {
        switch self {
        case .destroyed: return kAXUIElementDestroyedNotification
        case .miniaturized: return kAXWindowMiniaturizedNotification
        case .deminiaturized: return kAXWindowDeminiaturizedNotification
        case .titleChanged: return kAXTitleChangedNotification
        }
    }
}

