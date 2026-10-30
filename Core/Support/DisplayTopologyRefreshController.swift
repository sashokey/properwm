import Foundation

@MainActor
final class DisplayTopologyRefreshController {
    typealias ScheduleAfter = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> DispatchWorkItem

    private static let retryDelays: [TimeInterval] = [0.5, 2.0]
    private let snapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let applySnapshot: (ScreenTopologySnapshot) -> Void
    private let onRetrySnapshot: (ScreenTopologySnapshot) -> Void
    private let scheduleAfter: ScheduleAfter
    private var retryGeneration = 0
    private var retryWorkItems: [DispatchWorkItem] = []

    init(
        snapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot,
        applySnapshot: @escaping (ScreenTopologySnapshot) -> Void,
        onRetrySnapshot: @escaping (ScreenTopologySnapshot) -> Void,
        scheduleAfter: @escaping ScheduleAfter
    ) {
        self.snapshotProvider = snapshotProvider
        self.applySnapshot = applySnapshot
        self.onRetrySnapshot = onRetrySnapshot
        self.scheduleAfter = scheduleAfter
    }

    func prepareForTopologyChange() -> ScreenTopologySnapshot {
        cancel()
        let snapshot = refreshedSnapshot()
        if needsUUIDRetry(snapshot) {
            let generation = retryGeneration
            retryWorkItems = Self.retryDelays.map { delay in
                scheduleAfter(delay) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.retryFired(generation: generation)
                    }
                }
            }
        }
        return snapshot
    }

    func cancel() {
        retryGeneration &+= 1
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems = []
    }

    private func refreshedSnapshot() -> ScreenTopologySnapshot {
        let snapshot = snapshotProvider()
        applySnapshot(snapshot)
        return snapshot
    }

    private func needsUUIDRetry(_ snapshot: ScreenTopologySnapshot) -> Bool {
        snapshot.physicalDisplayCount >= 2
            && snapshot.identifiedDisplayUUIDs.count < snapshot.physicalDisplayCount
    }

    private func retryFired(generation: Int) {
        guard generation == retryGeneration else { return }
        let snapshot = refreshedSnapshot()
        onRetrySnapshot(snapshot)
        if !needsUUIDRetry(snapshot) { cancel() }
    }
}
