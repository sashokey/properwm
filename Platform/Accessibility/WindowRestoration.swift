import ApplicationServices
import Foundation

struct WindowRestorationFrames: Sendable {
    let nativeAppKit: CGRect
    let targetAppKit: CGRect
    let nativeQuartz: CGRect
    let targetQuartz: CGRect
    let primaryScreenHeight: CGFloat
}

enum WindowRestorationOutcome: Equatable, Sendable {
    case handled
    case retry
}

protocol WindowRestorationAccess: Sendable {
    associatedtype Handle: Sendable
    func processStartTime(pid: pid_t) -> timeval?
    func capture(_ key: WindowLiftAvoidance.WindowKey) -> Handle?
    func frame(_ handle: Handle) -> CGRect?
    func write(_ frame: CGRect, to handle: Handle, matching current: CGRect) -> AXWindowFrameWriteResult
}

struct AXWindowRestorationAccess: WindowRestorationAccess {
    private let reader = AXWindowReader()

    func processStartTime(pid: pid_t) -> timeval? { ProcessLiveness.startTime(pid: pid) }

    func capture(_ key: WindowLiftAvoidance.WindowKey) -> AXElementKey? {
        reader.captureHandle(forPID: key.pid, cgWindowID: key.cgWindowID, messagingTimeout: 0.1)
            .map { AXElementKey(e: $0.element) }
    }

    func frame(_ handle: AXElementKey) -> CGRect? { reader.frame(of: handle.e, messagingTimeout: 0.1) }

    func write(_ frame: CGRect, to handle: AXElementKey, matching current: CGRect) -> AXWindowFrameWriteResult {
        reader.setFrame(frame, for: handle.e, messagingTimeout: 0.1,
                        verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                        onlyIfCurrentMatches: current, restoreOnFailureTo: current)
    }
}

struct WindowRestorer<Access: WindowRestorationAccess>: Sendable {
    let access: Access

    func restore(key: WindowLiftAvoidance.WindowKey, frames: WindowRestorationFrames,
                 expectedStartTime: timeval?, liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?,
                 cancellation: OperationCancellation = OperationCancellation()) -> WindowRestorationOutcome {
        guard !cancellation.isCancelled else { return .retry }
        if let expectedStartTime {
            guard let current = access.processStartTime(pid: key.pid) else {
                return liveWindowKeys?.contains(key) == false ? .handled : .retry
            }
            guard current.tv_sec == expectedStartTime.tv_sec, current.tv_usec == expectedStartTime.tv_usec else { return .handled }
        }
        if liveWindowKeys?.contains(key) == false { return .handled }
        guard let handle = access.capture(key), let current = access.frame(handle) else { return .retry }
        let appKitFrame = WindowLiftAvoidance.appKitFrame(fromQuartz: current, primaryScreenHeight: frames.primaryScreenHeight)
        switch WindowLiftAvoidance.frameClassification(of: appKitFrame, nativeFrame: frames.nativeAppKit,
                                                       targetFrame: frames.targetAppKit) {
        case .target, .managedTrajectory: break
        case .native, .external: return .handled
        }
        guard !cancellation.isCancelled else { return .retry }
        switch access.write(frames.nativeQuartz, to: handle, matching: current) {
        case .success: return .handled
        case .failure: return .retry
        }
    }
}
