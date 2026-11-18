import Foundation

final class PendingCloseTracker {
    private static let expirationWindow: TimeInterval = 2.0
    private var requestsByWindowID: [WindowID: Date] = [:]

    func process(_ observation: SystemObservation, for window: WindowRecord, closeRequestedAt: Date?) -> Bool {
        let observedCGWindowID = observation.cgWindowID
        let identityChanged = window.pid != observation.pid
            || (observedCGWindowID != nil && window.cgWindowID != observedCGWindowID)
        if identityChanged {
            if observation.kind != .disappeared {
                requestsByWindowID.removeValue(forKey: window.id)
            }
            return false
        }

        let wasPresent = window.status != .disappeared && window.status != .closedPending
        if !wasPresent, observation.kind != .disappeared {
            requestsByWindowID.removeValue(forKey: window.id)
        }
        if wasPresent, observedCGWindowID != nil, let closeRequestedAt {
            requestsByWindowID[window.id] = closeRequestedAt
        }

        guard observation.kind == .disappeared,
              observation.source == .coreGraphics, observedCGWindowID != nil,
              let requestedAt = requestsByWindowID.removeValue(forKey: window.id) else { return false }
        return (0...Self.expirationWindow).contains(observation.timestamp.timeIntervalSince(requestedAt))
    }
}
