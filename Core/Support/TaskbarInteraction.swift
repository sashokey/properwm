import Foundation

enum TaskbarMotion {
    static let buttonTransition: TimeInterval = 0.12
    static let reorderTransition: TimeInterval = 0.16
}

struct TaskbarDragGeometry {
    let grabOffsetX: CGFloat

    static func make(pointer: CGPoint, groupFrame: CGRect) -> Self {
        Self(grabOffsetX: min(max(0, pointer.x - groupFrame.minX), groupFrame.width))
    }

    func frame(pointer: CGPoint, groupWidth: CGFloat, occupiedBounds: CGRect) -> CGRect {
        let width = min(max(0, groupWidth), max(0, occupiedBounds.width))
        let x = min(max(occupiedBounds.minX, pointer.x - grabOffsetX), occupiedBounds.maxX - width)
        return CGRect(x: x, y: TaskbarMetrics.buttonTop, width: width, height: TaskbarMetrics.buttonHeight)
    }
}

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

    mutating func update(groupID: String, draggedFrame: CGRect, buttons: [TaskbarButtonLayout], liveGroups: [String]) {
        var frames: [(id: String, frame: CGRect)] = []
        for button in buttons {
            if let last = frames.indices.last, frames[last].id == button.groupID {
                frames[last].frame = frames[last].frame.union(button.frame)
            } else {
                frames.append((button.groupID, button.frame))
            }
        }
        guard let index = frames.firstIndex(where: { $0.id == groupID }) else {
            cancel()
            return
        }
        if let neighbor = frames.prefix(index).first(where: { draggedFrame.minX < $0.frame.midX }) {
            update(groupID: groupID, target: neighbor.id, after: false, liveGroups: liveGroups)
        } else if let neighbor = frames.suffix(from: index + 1).last(where: { draggedFrame.maxX > $0.frame.midX }) {
            update(groupID: groupID, target: neighbor.id, after: true, liveGroups: liveGroups)
        }
    }

    mutating func update(groupID: String, target: String, after: Bool, liveGroups: [String]) {
        guard groupID != target, liveGroups.contains(groupID), liveGroups.contains(target),
              TaskbarGroupOrdering.moving(groupID, relativeTo: target, after: after,
                                         order: liveGroups, appKeys: [:]) != liveGroups else {
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
