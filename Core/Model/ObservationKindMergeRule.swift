enum ObservationKindMergeRule {
    static func preferred(
        _ lhs: SystemObservation.ObservationKind?,
        _ rhs: SystemObservation.ObservationKind
    ) -> SystemObservation.ObservationKind {
        guard let lhs, lhs.mergePriority <= rhs.mergePriority else { return rhs }
        return lhs
    }
}

private extension SystemObservation.ObservationKind {
    var mergePriority: Int {
        switch self {
        case .hidden: 0
        case .minimized: 1
        case .unhidden: 2
        case .restored: 3
        case .appeared: 4
        case .disappeared: 5
        case .titleChanged: 6
        case .unchanged: 7
        }
    }
}
