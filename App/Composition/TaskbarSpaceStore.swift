import AppKit
import Combine

@MainActor
final class TaskbarSpaceStore: ObservableObject {
    @Published private(set) var snapshot = WindowSpaceSnapshot()
    @Published private(set) var confirmedSpaceRevision: UInt64 = 0
    private let activeSpaceChange = PassthroughSubject<Void, Never>()
    var activeSpaceChanges: AnyPublisher<Void, Never> { activeSpaceChange.eraseToAnyPublisher() }
    private let read: @Sendable ([WindowSpaceRequest], OperationCancellation) -> WindowSpaceSnapshot?
    private let notifications: NotificationCenter
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.window-spaces", qos: .utility)
    private let work = AsyncWorkScope()
    private var subscriptions = Set<AnyCancellable>()
    private var spaceObserver: NSObjectProtocol?
    private var timer: Timer?
    private var requests: [WindowSpaceRequest] = []
    private var revision: UInt64 = 0
    private var spaceRevision: UInt64 = 0
    private var invalidatedDisplays: Set<String> = []
    private var inFlight = false
    private var needsRefresh = false
    private var isRunning = false
    private var receivedInventory = false

    init(read: (@Sendable ([WindowSpaceRequest]) -> WindowSpaceSnapshot?)? = nil,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         pollInterval: TimeInterval = 5) {
        self.read = { requests, cancellation in
            if let read { return read(requests) }
            return WindowSpaceObservation.capture(requests, cancellation: cancellation, mode: .live)
        }
        self.notifications = notifications
        self.pollInterval = pollInterval
    }

    func start(snapshots: AnyPublisher<DockSnapshot, Never>) {
        guard !isRunning else { return }
        isRunning = true
        work.restart()
        let generation = work.generation
        spaceObserver = notifications.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.work.isCurrent(generation) else { return }
                self.activeSpaceChanged()
            }
        }
        notifications.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.work.isCurrent(generation) else { return }
                self.refresh()
            }.store(in: &subscriptions)
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
        if let spaceObserver { notifications.removeObserver(spaceObserver) }
        spaceObserver = nil
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

    func canUseProjection(on displayUUID: String?, renderedSpaceRevision: UInt64) -> Bool {
        if renderedSpaceRevision == spaceRevision { return true }
        guard let displayUUID else { return invalidatedDisplays.isEmpty }
        return !invalidatedDisplays.contains(displayUUID) && !invalidatedDisplays.contains("Main")
    }

    private func activeSpaceChanged() {
        if !snapshot.layouts.isEmpty {
            invalidatedDisplays = Set(snapshot.layouts.keys)
            spaceRevision &+= 1
        }
        activeSpaceChange.send()
        refresh()
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
            let observation = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                read(requests, cancellation)
            } ?? nil
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.isRunning else { return }
                self.inFlight = false
                if self.revision == revision {
                    let spaceRevision = self.spaceRevision
                    self.publish(self.snapshot.updating(with: observation, requests: requests,
                        afterSpaceChange: self.confirmedSpaceRevision != spaceRevision))
                    if let observation, !observation.layouts.isEmpty,
                       self.confirmedSpaceRevision != spaceRevision {
                        self.confirmedSpaceRevision = spaceRevision
                    }
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
