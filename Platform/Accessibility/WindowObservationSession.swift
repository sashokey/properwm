import ApplicationServices
import Foundation

protocol WindowObservationSession: Sendable {
    func add(_ notification: String, element: AXElementKey?) -> AXError
    func remove(_ notification: String, element: AXElementKey)
    @MainActor func attach()
    @MainActor func detach()
}

final class AXWindowObservationSession: WindowObservationSession, @unchecked Sendable {
    private final class Callback: Sendable {
        let receive: @Sendable (AXElementKey, String) -> Void
        init(_ receive: @escaping @Sendable (AXElementKey, String) -> Void) { self.receive = receive }
    }

    private let observer: AXObserver
    private let application: AXUIElement
    private let callback: Callback

    init?(pid: pid_t, receive: @escaping @Sendable (AXElementKey, String) -> Void) {
        guard AXIsProcessTrusted() else { return nil }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let callback = Unmanaged<Callback>.fromOpaque(refcon).takeUnretainedValue()
            callback.receive(AXElementKey(e: element), notification as String)
        }, &observer) == .success, let observer else { return nil }
        self.observer = observer
        application = AXUIElementCreateApplication(pid)
        callback = Callback(receive)
    }

    func add(_ notification: String, element: AXElementKey?) -> AXError {
        let target = element?.e ?? application
        AXUIElementSetMessagingTimeout(target, 0.05)
        return AXObserverAddNotification(observer, target, notification as CFString,
                                         Unmanaged.passUnretained(callback).toOpaque())
    }

    func remove(_ notification: String, element: AXElementKey) {
        AXUIElementSetMessagingTimeout(element.e, 0.05)
        AXObserverRemoveNotification(observer, element.e, notification as CFString)
    }

    @MainActor func attach() {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @MainActor func detach() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
