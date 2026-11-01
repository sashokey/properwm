import Foundation

struct FullscreenProbeRequest: Sendable {
    let pid: pid_t?
    let screenFrame: CGRect
    let generation: UInt64
    let spaceGeneration: UInt64?
    let finalConfirmation: Bool
    let source: String
}

struct FullscreenAXProbe: Sendable {
    let verdict: FullscreenAXVerdict
    let overlayWindowID: UInt32?
}

@MainActor
final class FullscreenProbeWorker {
    private let read: @Sendable (FullscreenProbeRequest) -> FullscreenAXProbe
    private let deliver: (FullscreenProbeRequest, FullscreenAXProbe) -> Void
    private let work = AsyncWorkScope()
    private var inFlight = false
    private var pending: FullscreenProbeRequest?

    init(read: @escaping @Sendable (FullscreenProbeRequest) -> FullscreenAXProbe,
         deliver: @escaping (FullscreenProbeRequest, FullscreenAXProbe) -> Void) {
        self.read = read
        self.deliver = deliver
    }

    func request(_ request: FullscreenProbeRequest) {
        guard work.isActive else { return }
        guard !inFlight else { pending = request; return }
        inFlight = true
        let read = read
        work.launch { [weak self] generation in
            guard let result = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), operation: {
                read(request)
            }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.inFlight = false
                if let pending = self.pending {
                    self.pending = nil
                    self.request(pending)
                } else {
                    self.deliver(request, result)
                }
            }
        }
    }

    func stop() {
        work.stop()
        pending = nil
        inFlight = false
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    isolated deinit { stop() }
}
