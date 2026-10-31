import Foundation
import Synchronization

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

    func launch(after delay: TimeInterval = 0, priority: TaskPriority? = nil,
                operation: @escaping @Sendable (UInt64) async -> Void) {
        guard isActive else { return }
        let id = UUID()
        let generation = generation
        tasks[id] = Task.detached(priority: priority) { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { await self?.finish(id); return }
            }
            if !Task.isCancelled { await operation(generation) }
            await self?.finish(id)
        }
    }

    #if DEBUG
    var pendingForTesting: [Task<Void, Never>] { Array(tasks.values) }
    #endif

    private func finish(_ id: UUID) { tasks.removeValue(forKey: id) }

    nonisolated static func performBlocking<Value: Sendable>(
        on queue: DispatchQueue = .global(qos: .userInitiated),
        operation: @escaping @Sendable () -> Value
    ) async -> Value? {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: operation())
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    isolated deinit {
        for task in tasks.values { task.cancel() }
    }
}
