import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum FocusedWindowRead: Sendable {
    case window(AXElementKey)
    case none
    case unavailable
}

private final class FocusedGeometryBinding: @unchecked Sendable {
    let session: any WindowObservationSession
    private var window: AXElementKey?
    private var applicationRegistered = false
    private let names = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]

    init(session: any WindowObservationSession) { self.session = session }

    func registerApplication(cancellation: OperationCancellation) -> Bool {
        if applicationRegistered { return true }
        var complete = true
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            guard !cancellation.isCancelled else { return false }
            if !Self.accepted(session.add(name, element: nil)) { complete = false }
        }
        applicationRegistered = complete
        return complete
    }

    func replaceWindow(with next: AXElementKey?, cancellation: OperationCancellation) -> Bool {
        guard !cancellation.isCancelled else { return false }
        let appReady = registerApplication(cancellation: cancellation)
        if let window {
            for name in names {
                guard !cancellation.isCancelled else { return false }
                session.remove(name, element: window)
            }
            self.window = nil
        }
        guard !cancellation.isCancelled else { return false }
        guard let next else { return appReady }
        window = next
        var complete = appReady
        for name in names {
            guard !cancellation.isCancelled else { return false }
            if !Self.accepted(session.add(name, element: next)) { complete = false }
        }
        return complete
    }

    private static func accepted(_ error: AXError) -> Bool {
        error == .success || error == .notificationAlreadyRegistered || error == .notificationUnsupported
    }

}

@MainActor
final class FrontmostWindowGeometryObserver {
    enum Event {
        case focusedWindowChanged
        case windowCreated
        case geometryChanged
        case windowDestroyed
    }

    typealias Factory = AppWindowObserver.Factory
    var onEvent: ((Event) -> Void)?
    private let makeSession: Factory
    private let readFocused: @Sendable (pid_t) -> FocusedWindowRead
    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.focused-geometry", qos: .utility)
    private let work = AsyncWorkScope()
    private var binding: FocusedGeometryBinding?
    private var activePID: pid_t?
    private var focusedWindow: AXElementKey?
    private var starting = false
    private var refreshing = false
    private var needsRefresh = false
    private var needsRetry = false
    private var bindingInFlight = false
    private var needsBinding = false
    private var needsBindingRetry = false
    private var bindingCancellation: OperationCancellation?

    init(makeSession: @escaping Factory = { AXWindowObservationSession(pid: $0, receive: $1) },
         readFocused: @escaping @Sendable (pid_t) -> FocusedWindowRead = FrontmostWindowGeometryObserver.readFocusedWindow) {
        self.makeSession = makeSession
        self.readFocused = readFocused
    }

    func start(pid: pid_t?) { activate(pid: pid) }

    func activate(pid: pid_t?) {
        if activePID == pid, binding != nil || starting {
            requestFocusedRefresh()
            return
        }
        stopObservation()
        guard let pid else { return }
        activePID = pid
        starting = true
        work.restart()
        let generation = work.generation
        let receive: @Sendable (AXElementKey, String) -> Void = { [weak self] element, name in
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleNotification(element, name: name)
            }
        }
        let makeSession = makeSession
        let queue = queue
        let cancellation = OperationCancellation()
        work.launch { [weak self] generation in
            let created = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                guard let session = makeSession(pid, receive), !cancellation.isCancelled else {
                    return nil as (FocusedGeometryBinding, Bool)?
                }
                let binding = FocusedGeometryBinding(session: session)
                return (binding, binding.registerApplication(cancellation: cancellation))
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.starting = false
                guard let (binding, registered) = created ?? nil else { return }
                self.binding = binding
                self.needsBindingRetry = !registered
                binding.session.attach()
                self.requestFocusedRefresh()
            }
        }
    }

    func stop() {
        stopObservation()
        onEvent = nil
    }

    private func stopObservation() {
        bindingCancellation?.cancel()
        work.stop()
        binding?.session.detach()
        binding = nil
        bindingCancellation = nil
        activePID = nil
        focusedWindow = nil
        starting = false
        refreshing = false
        needsRefresh = false
        needsRetry = false
        bindingInFlight = false
        needsBinding = false
        needsBindingRetry = false
    }

    private func requestFocusedRefresh() {
        guard let pid = activePID, binding != nil else { return }
        guard !refreshing else { needsRefresh = true; return }
        refreshing = true
        let readFocused = readFocused
        let queue = queue
        work.launch { [weak self] generation in
            guard let result = await AsyncWorkScope.performBlocking(on: queue, operation: { readFocused(pid) }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.refreshing = false
                self.needsRetry = false
                switch result {
                case let .window(element):
                    self.updateFocusedWindow(element)
                    self.onEvent?(.focusedWindowChanged)
                case .none:
                    self.updateFocusedWindow(nil)
                case .unavailable:
                    self.needsRetry = true
                }
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.requestFocusedRefresh()
                }
            }
        }
    }

    func retryUnavailableObservation() {
        if binding == nil, !starting, let activePID { activate(pid: activePID); return }
        if needsRetry, !refreshing { requestFocusedRefresh() }
        if needsBindingRetry, !bindingInFlight { beginBinding() }
    }

    private func updateFocusedWindow(_ next: AXElementKey?) {
        guard next != focusedWindow else { return }
        focusedWindow = next
        bindingCancellation?.cancel()
        if bindingInFlight { needsBinding = true }
        else { beginBinding() }
    }

    private func beginBinding() {
        guard let binding else { return }
        bindingInFlight = true
        let next = focusedWindow
        let cancellation = OperationCancellation()
        bindingCancellation = cancellation
        let queue = queue
        work.launch { [weak self] generation in
            let registered = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                binding.replaceWindow(with: next, cancellation: cancellation)
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.bindingInFlight = false
                self.bindingCancellation = nil
                self.needsBindingRetry = registered != true
                if self.needsBinding {
                    self.needsBinding = false
                    self.beginBinding()
                }
            }
        }
    }

    private func handleNotification(_ element: AXElementKey, name: String) {
        if name == kAXFocusedWindowChangedNotification {
            onEvent?(.focusedWindowChanged)
            requestFocusedRefresh()
        } else if name == kAXWindowCreatedNotification {
            onEvent?(.windowCreated)
            requestFocusedRefresh()
        } else if element == focusedWindow {
            if name == kAXWindowMovedNotification || name == kAXWindowResizedNotification {
                onEvent?(.geometryChanged)
            } else if name == kAXUIElementDestroyedNotification {
                onEvent?(.windowDestroyed)
                updateFocusedWindow(nil)
                requestFocusedRefresh()
            }
        }
    }

    nonisolated private static func readFocusedWindow(pid: pid_t) -> FocusedWindowRead {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        if error == .noValue { return .none }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        return .window(AXElementKey(e: value as! AXUIElement))
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    var isObservingForTesting: Bool { binding != nil }
    #endif

    isolated deinit {
        bindingCancellation?.cancel()
        binding?.session.detach()
        work.stop()
    }
}
