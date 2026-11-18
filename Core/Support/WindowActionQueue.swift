import Foundation

@MainActor
final class WindowActionQueue {
    private struct Job: Sendable {
        let key: String
        let kind: PlatformActionRequest.ActionKind?
        let cancellation: OperationCancellation
        let operation: @Sendable (UInt64, OperationCancellation) async -> Void
    }

    private(set) var generation: UInt64 = 0
    private var isActive = true
    private var pending: [Job] = []
    private var latestJobs: [String: Job] = [:]
    private var worker: Task<Void, Never>?
    private var tail: Task<Void, Never>?

    func restart() {
        stop()
        isActive = true
    }

    func stop() {
        generation &+= 1
        isActive = false
        for job in latestJobs.values { job.cancellation.cancel() }
        latestJobs.removeAll()
        pending.removeAll()
        worker?.cancel()
        worker = nil
    }

    func isCurrent(_ generation: UInt64) -> Bool { isActive && self.generation == generation }

    func contains(key: String, kind: PlatformActionRequest.ActionKind) -> Bool {
        latestJobs[key]?.kind == kind
    }

    @discardableResult
    func submit(
        key: String, kind: PlatformActionRequest.ActionKind? = nil, maximumPendingKeys: Int = 32,
        operation: @escaping @Sendable (UInt64, OperationCancellation) async -> Void
    ) -> Bool {
        guard isActive, pending.count < max(1, maximumPendingKeys) || pending.contains(where: { $0.key == key }) else { return false }
        cancel(key: key)
        let job = Job(key: key, kind: kind, cancellation: OperationCancellation(), operation: operation)
        latestJobs[key] = job
        pending.append(job)
        guard worker == nil else { return true }
        let previous = tail
        let generation = generation
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            while !Task.isCancelled, let job = await self?.next(generation: generation) {
                if !job.cancellation.isCancelled { await job.operation(generation, job.cancellation) }
                await self?.finish(job: job)
            }
        }
        worker = task
        tail = task
        return true
    }

    func cancel(key: String) {
        latestJobs.removeValue(forKey: key)?.cancellation.cancel()
        pending.removeAll { $0.key == key }
    }

    func retain(windowIDs: Set<String>) {
        for (key, job) in latestJobs where !windowIDs.contains(key) {
            job.cancellation.cancel()
            latestJobs.removeValue(forKey: key)
        }
        pending.removeAll { !windowIDs.contains($0.key) }
    }

    private func next(generation: UInt64) -> Job? {
        guard isCurrent(generation) else { return nil }
        guard !pending.isEmpty else { worker = nil; return nil }
        return pending.removeFirst()
    }

    private func finish(job: Job) {
        if latestJobs[job.key]?.cancellation === job.cancellation { latestJobs[job.key] = nil }
    }

    #if DEBUG
    var pendingForTesting: [Task<Void, Never>] { tail.map { [$0] } ?? [] }
    #endif

    isolated deinit { stop() }
}
