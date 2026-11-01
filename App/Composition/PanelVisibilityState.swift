import ApplicationServices
import CoreGraphics
import Foundation

enum PanelVisibilityReason: Hashable {
    case fullscreen
}

struct DiagnosticVisibilityChange: Equatable {
    let at: Date
    let unit: String
    let screen: String
    let visible: Bool
    let reasons: [String]
    let source: String
}

struct DiagnosticVisibilityHistory {
    private(set) var changes: [DiagnosticVisibilityChange] = []
    private var visibilityByUnit: [String: Bool] = [:]

    @discardableResult
    mutating func noteVisibilityChange(
        unit: String, screen: String, previousVisible: Bool, visible: Bool,
        reasons: Set<PanelVisibilityReason>, source: String, at: Date = Date()
    ) -> DiagnosticVisibilityChange? {
        let previous = visibilityByUnit[unit] ?? previousVisible
        visibilityByUnit[unit] = visible
        guard previous != visible else { return nil }
        let change = DiagnosticVisibilityChange(at: at, unit: unit, screen: screen, visible: visible,
                                               reasons: Self.reasonNames(reasons), source: source)
        changes.append(change)
        if changes.count > 40 { changes.removeFirst(changes.count - 40) }
        return change
    }

    mutating func remove(unit: String) { visibilityByUnit.removeValue(forKey: unit) }

    static func reasonNames(_ reasons: Set<PanelVisibilityReason>) -> [String] {
        reasons.map { reason in
            switch reason {
            case .fullscreen: return "fullscreen"
            }
        }.sorted()
    }
}

@MainActor
final class DiagnosticVisibilityRecorder {
    static let shared = DiagnosticVisibilityRecorder()
    var history = DiagnosticVisibilityHistory()
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
        isFullscreenVerdict: Bool,
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
