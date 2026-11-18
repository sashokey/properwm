import AppKit
import ApplicationServices

final class FinderSource {
    private let reader = AXWindowReader()
    private var history = AXObservationHistory()

    func observe() -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && FinderWindowRules.isFinder(bundleIdentifier: $0.bundleIdentifier)
        }

        return history.observe(apps, reader: reader) { window, _ in
            FinderWindowRules.isTrackable(
                title: window.title,
                role: window.role,
                subrole: window.subrole,
                bounds: window.bounds,
                isMinimized: window.isMinimized
            )
        }
    }
}
