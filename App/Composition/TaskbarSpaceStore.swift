import AppKit
import Combine

@MainActor
final class TaskbarSpaceStore: ObservableObject {
    @Published private(set) var snapshot = WindowSpaceSnapshot()
    private let read: @Sendable ([WindowSpaceRequest], OperationCancellation) -> WindowSpaceSnapshot?
    private let notifications: NotificationCenter
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.window-spaces", qos: .utility)
    private let work = AsyncWorkScope()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var requests: [WindowSpaceRequest] = []
    private var revision: UInt64 = 0
    private var inFlight = false
    private var needsRefresh = false
    private var isRunning = false
    private var receivedInventory = false

    init(read: (@Sendable ([WindowSpaceRequest]) -> WindowSpaceSnapshot?)? = nil,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         pollInterval: TimeInterval = 5) {
        self.read = { requests, cancellation in
            if let read { return read(requests) }
            return WindowSpaceObservation.capture(requests, cancellation: cancellation)
        }
        self.notifications = notifications
        self.pollInterval = pollInterval
    }

    func start(snapshots: AnyPublisher<DockSnapshot, Never>) {
        guard !isRunning else { return }
        isRunning = true
        work.restart()
        let generation = work.generation
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            notifications.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.work.isCurrent(generation) else { return }
                    self.refresh()
                }
            }.store(in: &subscriptions)
        }
        snapshots.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.work.isCurrent(generation) else { return }
            self.updateWindows(from: $0)
        }.store(in: &subscriptions)
        if pollInterval > 0 {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            timer.tolerance = min(0.5, pollInterval / 10)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        isRunning = false
        work.stop()
        subscriptions.removeAll()
        timer?.invalidate()
        timer = nil
        inFlight = false
        needsRefresh = false
        receivedInventory = false
    }

    func refresh() {
        guard isRunning else { return }
        revision &+= 1
        if inFlight { needsRefresh = true; return }
        beginRead()
    }

    private func updateWindows(from source: DockSnapshot) {
        let next = StripItem.openWindows(from: source).compactMap { item -> WindowSpaceRequest? in
            guard let identity = item.spaceIdentity else { return nil }
            return WindowSpaceRequest(identity: identity,
                isParked: item.status == WindowStatus.minimized.rawValue || item.status == WindowStatus.hidden.rawValue,
                isOnDesktop: item.isOnDesktop, displayUUID: item.displayUUID)
        }
        guard !receivedInventory || next != requests else { return }
        receivedInventory = true
        requests = next
        publish(snapshot.updating(with: nil, requests: next))
        refresh()
    }

    private func beginRead() {
        inFlight = true
        let requests = requests
        let revision = revision
        let read = read
        let queue = queue
        work.launch { [weak self] generation in
            let cancellation = OperationCancellation()
            let observation = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) { read(requests, cancellation) }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.isRunning else { return }
                self.inFlight = false
                if self.revision == revision {
                    self.publish(self.snapshot.updating(with: observation ?? nil, requests: requests))
                }
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.beginRead()
                }
            }
        }
    }

    private func publish(_ next: WindowSpaceSnapshot) {
        if snapshot != next { snapshot = next }
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    isolated deinit { stop() }
}
