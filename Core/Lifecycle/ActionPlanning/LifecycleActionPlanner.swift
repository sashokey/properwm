import AppKit
import Foundation

enum UserIntentAction: String, Hashable, Sendable {
    case toggle
    case activate
    case minimize
    case close
}

enum UserIntent: Hashable, Sendable {
    case toggle(WindowID)
    case activate(WindowID)
    case minimize(WindowID)
    case close(WindowID)

    var windowID: WindowID {
        switch self {
        case let .toggle(id), let .activate(id), let .minimize(id), let .close(id):
            return id
        }
    }

    var action: UserIntentAction {
        switch self {
        case .toggle:
            return .toggle
        case .activate:
            return .activate
        case .minimize:
            return .minimize
        case .close:
            return .close
        }
    }
}

final class LifecycleActionPlanner {
    private let isAppFrontmost: (pid_t) -> Bool
    private static let staleActiveGuardEnabled =
        DebugSwitch.staleActiveGuard.isEnabled(in: ProcessInfo.processInfo.environment)

    init(isAppFrontmost: @escaping (pid_t) -> Bool = {
        NSRunningApplication(processIdentifier: $0)?.isActive == true
    }) {
        self.isAppFrontmost = isAppFrontmost
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        optimisticStates: [String: OptimisticWindowState] = [:]
    ) -> PlatformActionRequest {
        switch intent {
        case let .toggle(id):
            guard let record = snapshot.windows[id] else {
                return PlatformActionRequest(kind: .activateWindow, windowID: id)
            }
            let optimistic = optimisticStates[id.rawValue]
            let status = optimistic?.status ?? record.status
            let appIsFrontmost = isAppFrontmost(record.pid)
            if record.id.rawValue.hasPrefix("app-") {
                return PlatformActionRequest(kind: .activateWindow, windowID: id)
            }
            if status == .active && appIsFrontmost {
                if Self.staleActiveGuardEnabled,
                   OptimisticWindowState.siblingActivationInFlight(
                       windowID: id.rawValue, optimisticStates: optimisticStates, snapshot: snapshot
                   ) {
                    return PlatformActionRequest(kind: .activateWindow, windowID: id)
                }
                return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
            }
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .activate(id):
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .minimize(id):
            return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
        case let .close(id):
            return PlatformActionRequest(kind: .closeWindow, windowID: id)
        }
    }
}
