final class PlacementEngine {
    func place(snapshot: DockSnapshot, lifecycle: LifecycleDecision) -> PlacementResult {
        let windowID = lifecycle.windowID
        var orderedWindowIDs = snapshot.orderedWindowIDs
        if lifecycle.newStatus == .closedPending {
            orderedWindowIDs.removeAll { $0 == windowID }
        } else if !orderedWindowIDs.contains(windowID) {
            orderedWindowIDs.append(windowID)
        }
        return PlacementResult(orderedWindowIDs: orderedWindowIDs)
    }
}
