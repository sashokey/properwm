import ApplicationServices
import Foundation

struct AXElementKey: Hashable, @unchecked Sendable {
    let e: AXUIElement
    static func == (l: AXElementKey, r: AXElementKey) -> Bool { CFEqual(l.e, r.e) }
    func hash(into h: inout Hasher) { h.combine(CFHash(e)) }
}

@MainActor
final class AppWindowObserver {
    typealias Factory = @Sendable (pid_t, @escaping @Sendable (AXElementKey, String) -> Void) -> (any WindowObservationSession)?
    let pid: pid_t
    private var session: (any WindowObservationSession)?
    private let makeSession: Factory
    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.window-subscriptions", qos: .utility)
    private let work = AsyncWorkScope()
    private var isStarting = false
    private var waitingWindows: [CGWindowID: AXElementKey] = [:]
    private struct RegistrationWork {
        let id = UUID()
        let cancellation = OperationCancellation()
    }
    private var inFlight: [CGWindowID: RegistrationWork] = [:]
    private var subscriptions = WindowSubscriptionLedger<AXElementKey>(instanceIDs: AppWindowObserver.instanceIDs)
    private static let instanceIDs = WindowSubscriptionInstanceIDs()
    private let clock: @Sendable () -> TimeInterval

    var isActive: Bool { session != nil }
    var onWindowCreated: ((pid_t) -> Void)?
    var onWindowDestroyed: ((pid_t, CGWindowID) -> Void)?
    var onWindowMinimized: ((pid_t, CGWindowID) -> Void)?
    var onWindowDeminiaturized: ((pid_t, CGWindowID) -> Void)?
    var onFocusedWindowChanged: ((pid_t) -> Void)?
    var onTitleChanged: ((pid_t, CGWindowID) -> Void)?
    var onSubscriptionDestroyNotified: ((pid_t, CGWindowID, UInt64?) -> Void)?
    var onSubscriptionAttempt: ((WindowSubscriptionAttemptReport) -> Void)?

    enum Registration {
        case none
        case scheduled
        case retryDue(WindowSubscriptionRetryCandidate<AXElementKey>)
    }

    nonisolated static let retryTimeLimit: TimeInterval = 0.05
    private static let dropsDestroyNotifications = DebugSwitch.simulateNoDestroy.isEnabled()

    init(pid: pid_t, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeSession: @escaping Factory = { AXWindowObservationSession(pid: $0, receive: $1) }) {
        self.pid = pid
        self.clock = clock
        self.makeSession = makeSession
    }

    isolated deinit { stop() }

    func start() {
        guard session == nil, !isStarting else { return }
        isStarting = true
        work.restart()
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
                let session = makeSession(pid, receive)
                guard !cancellation.isCancelled else { return nil as (any WindowObservationSession)? }
                _ = session?.add(kAXWindowCreatedNotification, element: nil)
                guard !cancellation.isCancelled else { return nil as (any WindowObservationSession)? }
                _ = session?.add(kAXFocusedWindowChangedNotification, element: nil)
                return session
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.isStarting = false
                guard let session = created ?? nil else { return }
                self.session = session
                session.attach()
                let windows = self.waitingWindows
                self.waitingWindows.removeAll()
                for (id, key) in windows { _ = self.registerWindow(key.e, cgWindowID: id) }
            }
        }
    }

    func stop() {
        for registration in inFlight.values { registration.cancellation.cancel() }
        work.stop()
        session?.detach()
        session = nil
        isStarting = false
        waitingWindows.removeAll()
        inFlight.removeAll()
        subscriptions.removeAll()
    }

    func registerWindow(_ element: AXUIElement, cgWindowID: CGWindowID) -> Registration {
        let key = AXElementKey(e: element)
        guard session != nil else {
            if isStarting { waitingWindows[cgWindowID] = key }
            return .none
        }
        if inFlight[cgWindowID] != nil, subscriptions.record(for: cgWindowID)?.element == key { return .none }
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
        guard session != nil, inFlight[candidate.cgWindowID] == nil, candidate.pid == pid else { return false }
        return subscriptions.attemptKind(cgWindowID: candidate.cgWindowID, element: candidate.element, now: clock()) == .retry
    }

    func performRetry(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>,
                      completion: @escaping @MainActor @Sendable (WindowSubscriptionAttemptReport) -> Void) {
        guard isRetryValid(candidate) else { return }
        schedule(key: candidate.element, cgWindowID: candidate.cgWindowID, kind: .retry, completion: completion)
    }

    func isCovered(cgWindowID: CGWindowID) -> Bool { subscriptions.isCovered(cgWindowID: cgWindowID) }

    func subscribedElement(cgWindowID: CGWindowID) -> (element: AXUIElement, instanceID: UInt64)? {
        subscriptions.record(for: cgWindowID).map { ($0.element.e, $0.instanceID) }
    }

    func retainSubscriptions(keep: Set<CGWindowID>) -> [(cgWindowID: CGWindowID, instanceID: UInt64)] {
        waitingWindows = waitingWindows.filter { keep.contains($0.key) }
        for (id, registration) in inFlight where !keep.contains(id) { registration.cancellation.cancel() }
        inFlight = inFlight.filter { keep.contains($0.key) }
        for (id, record) in subscriptions.records where !keep.contains(id) {
            inFlight[id] = nil
            remove(record.element)
        }
        return subscriptions.retain(keep: keep)
    }

    private func remove(_ key: AXElementKey) {
        guard let session else { return }
        queue.async {
            for item in WindowSubscriptionItem.allCases { session.remove(item.notificationName, element: key) }
        }
    }

    private struct AttemptResult: Sendable {
        let results: [WindowSubscriptionItem: AXError]
        let sawFailure: Bool
        let stop: WindowSubscriptionStop
        let duration: TimeInterval
    }

    private func schedule(key: AXElementKey, cgWindowID: CGWindowID, kind: WindowSubscriptionAttemptKind,
                          completion: (@MainActor @Sendable (WindowSubscriptionAttemptReport) -> Void)? = nil) {
        guard let session else { return }
        inFlight[cgWindowID]?.cancellation.cancel()
        if let old = subscriptions.record(for: cgWindowID), old.element != key { remove(old.element) }
        let begun = subscriptions.beginAttempt(cgWindowID: cgWindowID, element: key, kind: kind, now: clock())
        let registration = RegistrationWork()
        let token = registration.id
        inFlight[cgWindowID] = registration
        let queue = queue
        let clock = clock
        let finish: @MainActor @Sendable (WindowSubscriptionAttemptReport) -> Void = completion ?? { [weak self] in self?.onSubscriptionAttempt?($0) }
        let cancellation = registration.cancellation
        work.launch { [weak self] generation in
            let result = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                let start = clock()
                var results: [WindowSubscriptionItem: AXError] = [:]
                var sawTimeout = false
                var sawFailure = false
                var stop: WindowSubscriptionStop = .completed
                attempt: for (index, item) in begun.items.enumerated() {
                    guard !cancellation.isCancelled else { break }
                    switch WindowSubscriptionAttemptPolicy.step(item: item, index: index, sawTimeout: sawTimeout,
                        elapsed: clock() - start, timeLimit: kind == .retry ? Self.retryTimeLimit : nil) {
                    case .send: break
                    case .skip: continue attempt
                    case .stop(let reason):
                        if let reason { stop = reason }
                        break attempt
                    }
                    let result = session.add(item.notificationName, element: key)
                    results[item] = result
                    if result == .invalidUIElement { stop = .dead; break }
                    if result == .cannotComplete { sawTimeout = true }
                    switch result {
                    case .success, .notificationAlreadyRegistered, .notificationUnsupported: break
                    default: sawFailure = true
                    }
                }
                if stop == .completed, sawTimeout { stop = .timeoutSkippedRest }
                return AttemptResult(results: results, sawFailure: sawFailure, stop: stop, duration: clock() - start)
            }
            guard let result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.inFlight[cgWindowID]?.id == token,
                      self.subscriptions.record(for: cgWindowID)?.instanceID == begun.instanceID else { return }
                self.inFlight[cgWindowID] = nil
                for (item, error) in result.results { self.subscriptions.record(cgWindowID: cgWindowID, item: item, result: error) }
                self.subscriptions.finishAttempt(cgWindowID: cgWindowID, now: clock(), sawFailure: result.sawFailure)
                finish(WindowSubscriptionAttemptReport(pid: self.pid, cgWindowID: cgWindowID, kind: kind,
                    instanceID: begun.instanceID, previousInstanceID: begun.previousInstanceID, results: result.results,
                    stop: result.stop, covered: self.subscriptions.isCovered(cgWindowID: cgWindowID), durationMs: result.duration * 1_000))
            }
        }
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    fileprivate func handleNotification(element: AXUIElement, notification notifStr: String) {
        if notifStr == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(pid)
        } else if notifStr == (kAXFocusedWindowChangedNotification as String) {
            onFocusedWindowChanged?(pid)
        } else if notifStr == (kAXUIElementDestroyedNotification as String) {
            if Self.dropsDestroyNotifications { return }
            // A destroyed element can no longer resolve its window id (`_AXUIElementGetWindow`
            // fails), so the subscription ledger is the lookup.
            if let hit = subscriptions.noteDestroyed(element: AXElementKey(e: element)) {
                if hit.removedInstanceID != nil {
                    inFlight[hit.cgWindowID]?.cancellation.cancel()
                    inFlight[hit.cgWindowID] = nil
                }
                onSubscriptionDestroyNotified?(pid, hit.cgWindowID, hit.removedInstanceID)
                onWindowDestroyed?(pid, hit.cgWindowID)
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

