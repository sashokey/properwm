import AppKit
import ApplicationServices
import Foundation
#if DEBUG
import OSLog
#endif

final class AccessibilitySource {
    #if DEBUG
    private static let logger = Logger(
        subsystem: DockWindowEligibilityPolicy.selfBundleIdentifier,
        category: "WindowFiltering"
    )
    #endif

    private let reader = AXWindowReader()
    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private var history = AXObservationHistory()

    func observe() -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.activationPolicy != .prohibited
                && FinderWindowRules.isFinder(bundleIdentifier: $0.bundleIdentifier) == false
        }

        return history.observe(apps, reader: reader) { [self] window, app in
            guard let title = window.title else { return false }
            let axDecision = AXTaskbarWindowRules.decision(
                role: window.role,
                subrole: window.subrole,
                bounds: window.bounds,
                isModal: window.isModal,
                isTopLevel: window.isTopLevel
            )
            guard axDecision.isAccepted else { return false }
            #if DEBUG
            logUnconfirmedWindowIfNeeded(axDecision, window: window, app: app)
            #endif

            return eligibilityPolicy.evaluate(
                DockWindowEligibilityPolicy.Candidate(
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.localizedName ?? "",
                    title: title,
                    subrole: window.subrole,
                    bounds: window.bounds,
                    alpha: nil,
                    activationPolicy: app.activationPolicy,
                    executablePath: app.executableURL?.path
                )
            ) == .keep
        }
    }

    #if DEBUG
    private func logUnconfirmedWindowIfNeeded(
        _ decision: AXTaskbarWindowRules.Decision,
        window: AXWindowSnapshot,
        app: NSRunningApplication
    ) {
        guard decision == .unconfirmedMainWindow else { return }
        Self.logger.debug(
            "Admitting AXWindow with missing subrole app=\(app.localizedName ?? "", privacy: .public) bundle=\(app.bundleIdentifier ?? "", privacy: .public) title=\(window.title ?? "", privacy: .private)"
        )
    }
    #endif
}

struct AXObservationHistory {
    private enum WindowKey: Hashable {
        case native(UInt32)
        case element(AXUIElement)

        var cgWindowID: UInt32? {
            if case let .native(id) = self { return id }
            return nil
        }
    }

    private struct ApplicationHistory {
        var observations: [WindowKey: SystemObservation] = [:]
        var keysByElement: [AXUIElement: WindowKey] = [:]

        func matchingKey(for element: AXUIElement, nativeKey: WindowKey?) -> WindowKey? {
            let elementKey = keysByElement[element]
            guard let nativeKey else { return elementKey }
            if observations[nativeKey] != nil { return nativeKey }
            if case .element? = elementKey { return elementKey }
            return nil
        }
    }

    private var previousByPID: [pid_t: ApplicationHistory] = [:]

    mutating func observe(
        _ apps: [NSRunningApplication],
        reader: AXWindowReader,
        admitting: (AXWindowSnapshot, NSRunningApplication) -> Bool
    ) -> [SystemObservation] {
        let now = Date()
        let runningPIDs = Set(apps.map(\.processIdentifier))
        previousByPID = previousByPID.filter { runningPIDs.contains($0.key) }

        return apps.flatMap { app -> [SystemObservation] in
            let pid = app.processIdentifier
            let result = reader.windowReadResult(forPID: pid)
            return update(pid: pid, at: now, isAppHidden: app.isHidden,
                          windows: result.isSuccess ? result.windowsOrEmpty : nil,
                          bundleIdentifier: app.bundleIdentifier, appName: app.localizedName) {
                admitting($0, app)
            }
        }
    }

    mutating func update(
        pid: pid_t,
        at timestamp: Date,
        isAppHidden: Bool,
        windows: [AXWindowSnapshot]?,
        bundleIdentifier: String? = nil,
        appName: String? = nil,
        admitting: (AXWindowSnapshot) -> Bool
    ) -> [SystemObservation] {
        guard let windows else { return [] }
        let previous = previousByPID[pid] ?? ApplicationHistory()
        var next = ApplicationHistory()
        var retained: [WindowKey: SystemObservation] = [:]
        var matchedPrevious: Set<WindowKey> = []
        var observations: [SystemObservation] = []

        for window in windows {
            let nativeKey = window.cgWindowID.flatMap { $0 == 0 ? nil : WindowKey.native($0) }
            let previousKey = previous.matchingKey(for: window.element, nativeKey: nativeKey)
            let previousObservation = previousKey.flatMap { previous.observations[$0] }
            let key = nativeKey ?? previousKey ?? .element(window.element)

            if case .unread = window.titleRead {
                guard let previousObservation else { continue }
                retained[key] = previousObservation
            } else {
                guard admitting(window) else { continue }
                let kind: SystemObservation.ObservationKind
                if window.isMinimized {
                    kind = .minimized
                } else if isAppHidden {
                    kind = .hidden
                } else if previousObservation?.kind == .hidden {
                    kind = .unhidden
                } else {
                    kind = .unchanged
                }

                let event = SystemObservation(
                    timestamp: timestamp, kind: kind, source: .accessibility, pid: pid,
                    bundleIdentifier: bundleIdentifier, cgWindowID: key.cgWindowID, title: window.title,
                    appName: appName, bounds: window.bounds, isMinimized: window.isMinimized,
                    isFocusedWindow: window.isFocusedWindow
                )
                if ObservationKindMergeRule.preferred(next.observations[key]?.kind, kind) == kind {
                    next.observations[key] = event
                }
                observations.append(event)
            }

            if let previousKey { matchedPrevious.insert(previousKey) }
            next.keysByElement[window.element] = key
        }

        next.observations.merge(retained) { current, _ in current }
        for (key, window) in previous.observations where !matchedPrevious.contains(key) {
            observations.append(SystemObservation(
                timestamp: timestamp, kind: .disappeared, source: window.source, pid: window.pid,
                bundleIdentifier: window.bundleIdentifier, cgWindowID: key.cgWindowID, title: window.title,
                appName: window.appName, bounds: window.bounds, isMinimized: window.isMinimized, isFocusedWindow: false
            ))
        }
        previousByPID[pid] = next.observations.isEmpty ? nil : next
        return observations
    }
}
