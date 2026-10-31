import Foundation

@MainActor
final class TaskbarDelayedAction {
    typealias Delay = @MainActor (Duration) async -> Void
    private let delay: Delay
    private var task: Task<Void, Never>?
    private(set) var target: String?

    init(delay: @escaping Delay = { try? await Task.sleep(for: $0) }) {
        self.delay = delay
    }

    func schedule(target: String, after duration: Duration, action: @escaping @MainActor () -> Void) {
        guard self.target != target else { return }
        cancel()
        self.target = target
        let delay = delay
        task = Task { @MainActor [weak self] in
            await delay(duration)
            guard !Task.isCancelled, self?.target == target else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        target = nil
    }

    isolated deinit { task?.cancel() }
}

struct TaskbarGroupDrag {
    struct Target: Equatable {
        let groupID: String
        let after: Bool
    }

    private(set) var groupID: String?
    private(set) var target: Target?

    mutating func update(groupID: String, target: String, after: Bool, liveGroups: [String]) {
        guard groupID != target, liveGroups.contains(groupID), liveGroups.contains(target) else {
            cancel()
            return
        }
        self.groupID = groupID
        self.target = Target(groupID: target, after: after)
    }

    func order(_ liveGroups: [String]) -> [String] {
        guard let groupID, let target else { return liveGroups }
        return TaskbarGroupOrdering.moving(groupID, relativeTo: target.groupID, after: target.after,
                                           order: liveGroups, appKeys: [:])
    }

    mutating func reconcile(liveGroups: [String]) {
        guard let groupID, let target else { return }
        if !liveGroups.contains(groupID) || !liveGroups.contains(target.groupID) { cancel() }
    }

    mutating func cancel() { groupID = nil; target = nil }
}
