import Foundation

@MainActor
final class WindowActionQueue {
    private(set) var generation: UInt64 = 0
    private var isActive = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [String: OperationCancellation] = [:]
    private var tail: Task<Void, Never>?

    func restart() {
        stop()
        isActive = true
    }

    func stop() {
        generation &+= 1
        isActive = false
        for cancellation in cancellations.values { cancellation.cancel() }
        cancellations.removeAll()
        let pending = tasks.values
        tasks.removeAll()
        for task in pending { task.cancel() }
    }

    func isCurrent(_ generation: UInt64) -> Bool { isActive && self.generation == generation }

    func submit(key: String, operation: @escaping @Sendable (UInt64, OperationCancellation) async -> Void) {
        guard isActive else { return }
        cancellations[key]?.cancel()
        let cancellation = OperationCancellation()
        cancellations[key] = cancellation
        let previous = tail
        let generation = generation
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            if !Task.isCancelled, !cancellation.isCancelled {
                await operation(generation, cancellation)
            }
            await self?.finish(id: id, key: key, cancellation: cancellation)
        }
        tasks[id] = task
        tail = task
    }

    private func finish(id: UUID, key: String, cancellation: OperationCancellation) {
        tasks[id] = nil
        if cancellations[key] === cancellation { cancellations[key] = nil }
    }

    #if DEBUG
    var pendingForTesting: [Task<Void, Never>] { Array(tasks.values) }
    #endif

    isolated deinit { stop() }
}
