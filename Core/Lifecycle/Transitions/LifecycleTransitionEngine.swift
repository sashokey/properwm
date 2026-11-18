final class LifecycleTransitionEngine {
    func transition(identity: IdentityDecision, observation: SystemObservation, snapshot: DockSnapshot) -> LifecycleDecision {
        let visibleStatus: WindowStatus = observation.isFocusedWindow ? .active : .inactive
        let status: WindowStatus
        switch observation.kind {
        case .appeared, .restored, .unhidden:
            status = visibleStatus
        case .titleChanged, .unchanged:
            let reportsVisibility = observation.source == .accessibility || observation.source == .appWindowInventory
            if reportsVisibility && !observation.isMinimized {
                status = visibleStatus
            } else {
                status = snapshot.windows[identity.windowID]?.status ?? .inactive
            }
        case .minimized:
            status = .minimized
        case .hidden:
            status = .hidden
        case .disappeared:
            status = .disappeared
        }
        return LifecycleDecision(
            windowID: identity.windowID,
            newStatus: status,
            requests: [],
            observedAt: observation.timestamp
        )
    }
}
