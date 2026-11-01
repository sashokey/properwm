import Foundation
import Synchronization

final class OperationCancellation: Sendable {
    private let cancelled = Mutex(false)

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }
}

@MainActor
final class AsyncWorkScope {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = true
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func restart() {
        stop()
        isActive = true
    }

    func stop() {
        generation &+= 1
        isActive = false
        let pending = tasks.values
        tasks.removeAll()
        for task in pending { task.cancel() }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }

    @discardableResult
    func launch(after delay: TimeInterval = 0, priority: TaskPriority? = nil,
                operation: @escaping @Sendable (UInt64) async -> Void) -> Task<Void, Never>? {
        guard isActive else { return nil }
        let id = UUID()
        let generation = generation
        let task = Task.detached(priority: priority) { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { await self?.finish(id); return }
            }
            if !Task.isCancelled { await operation(generation) }
            await self?.finish(id)
        }
        tasks[id] = task
        return task
    }

    #if DEBUG
    var pendingForTesting: [Task<Void, Never>] { Array(tasks.values) }
    #endif

    private func finish(_ id: UUID) { tasks.removeValue(forKey: id) }

    nonisolated static func performBlocking<Value>(
        on queue: DispatchQueue = .global(qos: .userInitiated),
        cancellation: OperationCancellation = OperationCancellation(),
        operation: @escaping @Sendable () -> sending Value
    ) async -> sending Value? {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: operation())
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    isolated deinit {
        for task in tasks.values { task.cancel() }
    }
}

struct OperationReadBudget: Sendable {
    let cancellation: OperationCancellation
    private let deadline: TimeInterval
    private let uptime: @Sendable () -> TimeInterval

    init(maximumDuration: TimeInterval, cancellation: OperationCancellation,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.cancellation = cancellation
        self.uptime = uptime
        deadline = uptime() + max(0, maximumDuration.isFinite ? maximumDuration : 0)
    }

    var remaining: TimeInterval { cancellation.isCancelled ? 0 : max(0, deadline - uptime()) }
    var canContinue: Bool { remaining > 0 }
}
