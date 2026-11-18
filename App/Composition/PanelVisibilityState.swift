import ApplicationServices
import CoreGraphics
import Foundation

enum PanelVisibilityReason: Hashable {
    case fullscreen
}

enum FullscreenSpaceHoldDisposition: Equatable {
    case apply
    case hold
    case stale
}

enum FullscreenSpaceHoldDecision {
    static let postSpaceConfirmationDelay: TimeInterval = 0.12
    static let activationFallbackDelay: TimeInterval = 0.5

    static func disposition(
        expectedGeneration: UInt64?,
        activeGeneration: UInt64?,
        isFinalWindowedConfirmation: Bool
    ) -> FullscreenSpaceHoldDisposition {
        guard let activeGeneration else {
            return expectedGeneration == nil ? .apply : .stale
        }
        guard expectedGeneration == activeGeneration else { return .stale }
        if isFinalWindowedConfirmation { return .apply }
        return .hold
    }
}

enum OverlayWindowWatch {
    static let tickInterval: TimeInterval = 0.25

    static func shouldRecheck(isOnscreen: Bool?, bounds: CGRect?, screenCGFrame: CGRect) -> Bool {
        guard let isOnscreen, isOnscreen, let bounds else { return true }
        let t = FullscreenWindowClassifier.frameTolerance
        return abs(bounds.width - screenCGFrame.width) >= t
            || abs(bounds.height - screenCGFrame.height) >= t
            || abs(bounds.minX - screenCGFrame.minX) >= t
            || abs(bounds.minY - screenCGFrame.minY) >= t
    }
}

enum AllSpacesMembership {
    static let maxRepairAttempts = 3
    static let verifyDelay: TimeInterval = 0.12

    static func missingSpaceIDs(windowSpaceIDs: [Int], desktopSpaceIDs: [Int]) -> [Int] {
        guard desktopSpaceIDs.count > 1 else { return [] }
        let owned = Set(windowSpaceIDs)
        return desktopSpaceIDs.filter { !owned.contains($0) }.sorted()
    }

    static func shouldRetry(attempt: Int) -> Bool { attempt < maxRepairAttempts }
}

struct PanelVisibilityState: Equatable {
    var hideReasons: Set<PanelVisibilityReason> = []

    var isVisible: Bool { hideReasons.isEmpty }

    mutating func setFullscreen(_ active: Bool) {
        setReason(.fullscreen, active: active)
    }

    private mutating func setReason(_ reason: PanelVisibilityReason, active: Bool) {
        if active {
            hideReasons.insert(reason)
        } else {
            hideReasons.remove(reason)
        }
    }
}
