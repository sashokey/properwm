import AppKit
import ApplicationServices
import Foundation
import OSLog

final class AccessibilitySource {
    private static let logger = Logger(
        subsystem: DockWindowEligibilityPolicy.selfBundleIdentifier,
        category: "WindowFiltering"
    )

    private let reader = AXWindowReader()
    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private var previousWindowKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
    private var previousObservationsBySignature: [String: SystemObservation] = [:]
    private var previousHiddenSignatures: Set<String> = []

    func observe() -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let now = Date()

        let apps = Array(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.activationPolicy != .prohibited
                && FinderWindowRules.isFinder(bundleIdentifier: $0.bundleIdentifier) == false
        })
        let scannedPIDs = Set(apps.map(\.processIdentifier))

        var observations: [SystemObservation] = []
        var currentHiddenSignatures: Set<String> = []

        for app in apps {
            let appObservations = observeWindows(for: app, now: now)
            observations.append(contentsOf: appObservations)

            for observation in appObservations {
                if observation.kind == .hidden {
                    currentHiddenSignatures.insert(observationSignature(observation))
                }
            }
        }

        var nextKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
        var nextObservationsBySignature: [String: SystemObservation] = [:]
        for observation in observations {
            let signature = observationSignature(observation)
            nextKindsBySignature[signature] = ObservationKindMergeRule.preferred(
                nextKindsBySignature[signature],
                observation.kind
            )
            nextObservationsBySignature[signature] = observation
        }

        for (signature, previous) in previousObservationsBySignature
            where nextObservationsBySignature[signature] == nil && scannedPIDs.contains(previous.pid) {
            observations.append(
                SystemObservation(
                    timestamp: now,
                    kind: .disappeared,
                    source: previous.source,
                    pid: previous.pid,
                    bundleIdentifier: previous.bundleIdentifier,
                    cgWindowID: previous.cgWindowID,
                    title: previous.title,
                    appName: previous.appName,
                    bounds: previous.bounds,
                    isMinimized: previous.isMinimized,
                    isFocusedWindow: false
                )
            )
        }

        previousWindowKindsBySignature = nextKindsBySignature
        previousObservationsBySignature = nextObservationsBySignature
        previousHiddenSignatures = currentHiddenSignatures
        return observations
    }

    private func observeWindows(for app: NSRunningApplication, now: Date) -> [SystemObservation] {
        let isAppHidden = app.isHidden

        return reader.windows(for: app).compactMap { window in
            let title = window.title
            guard title != nil else { return nil }
            let axDecision = AXTaskbarWindowRules.decision(
                role: window.role,
                subrole: window.subrole,
                bounds: window.bounds
            )
            guard axDecision.isAccepted else { return nil }
            logUnconfirmedWindowIfNeeded(axDecision, window: window, app: app)

            let decision = eligibilityPolicy.evaluate(
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
            )
            guard decision == .keep else { return nil }

            let baseObservation = SystemObservation(
                timestamp: now,
                kind: .unchanged,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
            let signature = observationSignature(baseObservation)
            let previousKind = previousWindowKindsBySignature[signature]
            let wasHidden = previousHiddenSignatures.contains(signature)
            let kind: SystemObservation.ObservationKind

            if window.isMinimized {
                kind = .minimized
            } else if isAppHidden {
                kind = .hidden
            } else if wasHidden || previousKind == .hidden {
                kind = .unhidden
            } else {
                kind = .unchanged
            }

            return SystemObservation(
                timestamp: now,
                kind: kind,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
        }
    }

    private func logUnconfirmedWindowIfNeeded(
        _ decision: AXTaskbarWindowRules.Decision,
        window: AXWindowSnapshot,
        app: NSRunningApplication
    ) {
        guard decision == .unconfirmedMainWindow else { return }
        Self.logger.debug(
            "Admitting AXWindow with missing subrole app=\(app.localizedName ?? "", privacy: .public) bundle=\(app.bundleIdentifier ?? "", privacy: .public) title=\(window.title ?? "", privacy: .public)"
        )
    }

    private func observationSignature(_ observation: SystemObservation) -> String {
        let title = observation.title?.lowercased() ?? "<untitled>"
        let frame = observation.bounds.map {
            "\($0.origin.x.rounded()):\($0.origin.y.rounded()):\($0.width.rounded()):\($0.height.rounded())"
        } ?? "<unknown>"
        return "\(observation.pid)|\(title)|\(frame)"
    }
}

struct AccessibilityWindowActionExecutor {
    private let reader: AXWindowReader
    private let chipProbeEnabled: Bool
    private static let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")

    init(reader: AXWindowReader = AXWindowReader(), chipProbeEnabled: Bool = false) {
        self.reader = reader
        self.chipProbeEnabled = chipProbeEnabled
    }

    struct ActionExecution {
        let success: Bool
        let mechanism: String
        let verifiedMinimized: Bool?
    }

    struct WindowTarget {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
    }

    struct WindowHandle {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
        fileprivate let element: AXUIElement
    }

    func captureHandleFromCache(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?
    ) -> WindowHandle? {
        guard let element = AXElementCache.shared.element(pid: pid, cgWindowID: cgWindowID) else {
            return nil
        }
        switch reader.matchesCGWindowID(cgWindowID, element: element, messagingTimeout: 0.05) {
        case .some(true):
            return WindowHandle(pid: pid, title: title, bounds: bounds, element: element)
        case .some(false):
            AXElementCache.shared.remove(pid: pid, cgWindowID: cgWindowID)
            return nil
        case .none:
            return nil
        }
    }

    func captureHandleByCGWindowID(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            forPID: pid,
            cgWindowID: cgWindowID,
            messagingTimeout: 0.1
        ) else { return nil }
        return Self.fastHandle(
            from: handle,
            target: WindowTarget(pid: pid, title: title, bounds: bounds)
        )
    }

    static func fastHandle(from handle: AXWindowHandle, target: WindowTarget) -> WindowHandle {
        return WindowHandle(
            pid: target.pid,
            title: target.title,
            bounds: target.bounds,
            element: handle.element
        )
    }

    func activateAppWithWindowRecovery(pid: Int32, runningApp: NSRunningApplication?) -> Bool {
        let liveWindows: [AXWindowSnapshot]
        switch reader.inventoryWindows(forPID: pid, messagingTimeout: 0.3) {
        case .success(let windows): liveWindows = windows
        case .unread: liveWindows = []
        }
        let visibleWindows = liveWindows.filter { !$0.isMinimized }

        if !visibleWindows.isEmpty {
            _ = AXUIElementPerformAction(visibleWindows[0].element, kAXRaiseAction as CFString)
            return runningApp?.activate(options: [.activateIgnoringOtherApps]) ?? false
        }

        return false
    }

    func captureHandle(
        for target: WindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            for: AXWindowTarget(pid: target.pid, title: target.title, bounds: target.bounds),
            attempts: attempts,
            retryIntervalMicroseconds: retryIntervalMicroseconds,
            messagingTimeout: 0.5
        ) else {
            return nil
        }
        return WindowHandle(
            pid: target.pid,
            title: handle.title,
            bounds: handle.bounds,
            element: handle.element
        )
    }

    func minimize(_ handle: WindowHandle) -> ActionExecution {
        if chipProbeEnabled {
            let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let subrole = reader.stringAttribute(kAXSubroleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let hasMinimizeButton = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) != nil
            let currentMinimized = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element, maxAttempts: 1)
            var minimizedSettable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(handle.element, kAXMinimizedAttribute as CFString, &minimizedSettable)
            let probeApp = NSRunningApplication(processIdentifier: handle.pid)
            let probePolicyStr: String
            switch probeApp?.activationPolicy {
            case .regular: probePolicyStr = "regular"
            case .accessory: probePolicyStr = "accessory"
            case .prohibited: probePolicyStr = "prohibited"
            default: probePolicyStr = "nil"
            }
            Self.chipProbeLogger.info("minimize-ax-probe app=\(probeApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(probeApp?.bundleIdentifier ?? "(none)", privacy: .public) activationPolicy=\(probePolicyStr, privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) hasMinimizeButton=\(hasMinimizeButton, privacy: .public) currentMinimized=\(String(describing: currentMinimized), privacy: .public) minimizedSettable=\(minimizedSettable.boolValue, privacy: .public)")
        }

        if setMinimized(true, for: handle) {
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            if verified == true {
                return ActionExecution(
                    success: true,
                    mechanism: "set-minimized-attribute",
                    verifiedMinimized: verified
                )
            }
        }

        guard let button = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) else {
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == true,
                mechanism: "missing-minimize-button",
                verifiedMinimized: verified
            )
        }

        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return ActionExecution(
                success: false,
                mechanism: "press-minimize-button-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
        return ActionExecution(
            success: verified == true,
            mechanism: "press-minimize-button",
            verifiedMinimized: verified
        )
    }

    func restore(_ handle: WindowHandle) -> ActionExecution {
        if setMinimized(false, for: handle) {
            _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == false,
                mechanism: "clear-minimized-attribute",
                verifiedMinimized: verified
            )
        }

        guard let rebound = recapture(from: handle) else {
            return ActionExecution(
                success: false,
                mechanism: "recapture-for-restore-failed",
                verifiedMinimized: nil
            )
        }
        guard setMinimized(false, for: rebound) else {
            return ActionExecution(
                success: false,
                mechanism: "clear-minimized-after-recapture-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
            )
        }
        _ = AXUIElementPerformAction(rebound.element, kAXRaiseAction as CFString)
        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
        return ActionExecution(
            success: verified == false,
            mechanism: "clear-minimized-after-recapture",
            verifiedMinimized: verified
        )
    }

    func activate(_ handle: WindowHandle) -> Bool {
        activate(handle, requiresFocusedConfirmation: false)
    }

    func activate(
        _ handle: WindowHandle,
        requiresFocusedConfirmation: Bool,
        confirmationTimeout: TimeInterval = 0.6,
        pollIntervalMicroseconds: useconds_t = 100_000,
        knownCGWindowID: CGWindowID? = nil,
        knownMinimized: Bool = false,
        preActivateForRestore: Bool = false,
        awaitOnScreenBeforeFocus: Bool = false
    ) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: handle.pid)
        if knownMinimized || reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element) == true {
            if preActivateForRestore, let wid = knownCGWindowID {
                postSkyLightFrontSwitchOnly(pid: handle.pid, windowID: wid)
            }
            _ = setMinimized(false, for: handle)
            if awaitOnScreenBeforeFocus, !preActivateForRestore, let wid = knownCGWindowID {
                waitForWindowOnScreen(wid)
            }
            if let wid = knownCGWindowID {
                postSkyLightWindowFocus(pid: handle.pid, windowID: wid)
            }
            AXUIElementSetAttributeValue(handle.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }

        let focusedViaSkyLight = focusWindowViaSkyLight(pid: handle.pid, element: handle.element)
        let raised = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
        if !focusedViaSkyLight, runningApp?.isActive != true {
            _ = runningApp?.activate(options: [.activateIgnoringOtherApps])
        }

        if requiresFocusedConfirmation {
            return confirmFocused(
                handle,
                timeout: confirmationTimeout,
                pollIntervalMicroseconds: pollIntervalMicroseconds
            )
        }

        return focusedViaSkyLight || raised || runningApp?.isActive == true
    }

    @discardableResult
    private func waitForWindowOnScreen(_ windowID: CGWindowID, cap: TimeInterval = 0.9) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + cap
        repeat {
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
               let info = list.first,
               (info[kCGWindowIsOnscreen as String] as? Bool) == true,
               (info[kCGWindowLayer as String] as? Int) == 0 {
                return true
            }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func close(_ handle: WindowHandle) -> Bool {
        let deadline = Date().addingTimeInterval(0.6)
        var attempts = 0
        repeat {
            attempts += 1
            var raw: CFTypeRef?
            let readError = AXUIElementCopyAttributeValue(handle.element, kAXCloseButtonAttribute as CFString, &raw)
            if readError == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let pressError = AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString)
                Self.chipProbeLogger.info("close-press pid=\(handle.pid, privacy: .public) error=\(pressError.rawValue, privacy: .public) attempt=\(attempts, privacy: .public)")
                if pressError == .success { return true }
                if pressError != .cannotComplete { return false }
            } else if readError != .cannotComplete {
                Self.chipProbeLogger.info("close-button-read failed pid=\(handle.pid, privacy: .public) error=\(readError.rawValue, privacy: .public)")
                return false
            }
            usleep(50_000)
        } while Date() < deadline
        Self.chipProbeLogger.info("close gave up pid=\(handle.pid, privacy: .public) attempts=\(attempts, privacy: .public)")
        return false
    }

    private func recapture(from handle: WindowHandle) -> WindowHandle? {
        captureHandle(
            for: WindowTarget(
                pid: handle.pid,
                title: handle.title,
                bounds: handle.bounds
            )
        )
    }

    private func confirmFocused(
        _ handle: WindowHandle,
        timeout: TimeInterval,
        pollIntervalMicroseconds: useconds_t
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isFocused(handle) {
                return true
            }
            if let rebound = recapture(from: handle),
               isFocused(rebound) {
                return true
            }
            usleep(pollIntervalMicroseconds)
        } while Date() < deadline

        return false
    }

    private func isFocused(_ handle: WindowHandle) -> Bool {
        guard let focusedWindow = reader.focusedWindow(forPID: handle.pid) else {
            return false
        }
        return CFEqual(focusedWindow, handle.element)
    }

    func findBackgroundActivationTarget(
        for handle: WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot,
        focusedReadBudget: TimeInterval = 0
    ) -> MinimizeHandoffTarget.Verdict {
        guard NSRunningApplication(processIdentifier: handle.pid)?.isActive == true else { return .none }

        let appElement = AXUIElementCreateApplication(handle.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        let deadline = Date().addingTimeInterval(focusedReadBudget)
        var focused: AXUIElement?
        var readError = AXError.success
        repeat {
            var raw: CFTypeRef?
            readError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw)
            if readError == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                focused = (raw as! AXUIElement)
            }
            guard readError == .cannotComplete, Date() < deadline else { break }
            usleep(20_000)
        } while true
        guard let focused, CFEqual(focused, handle.element) else {
            Self.chipProbeLogger.info("postactivate-target focused-gate failed pid=\(handle.pid, privacy: .public) readError=\(readError.rawValue, privacy: .public)")
            return .none
        }

        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return .none }

        var zOrder: [MinimizeHandoffTarget.ZOrderedWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ourPID else { continue }
            guard let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }
            zOrder.append(.init(pid: ownerPID, cgWindowID: CGWindowID(wid)))
        }

        let verdict = MinimizeHandoffTarget.select(zOrder: zOrder, target: record, snapshot: snapshot)
        switch verdict {
        case .switchTo(let pid, let wid, let windowID):
            Self.chipProbeLogger.info(
                "postactivate-target candidate=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "(unknown)", privacy: .public) pid=\(pid, privacy: .public) wid=\(wid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)"
            )
        case .siblingTakesOver(let windowID):
            Self.chipProbeLogger.info("postactivate-target sibling-takes-over pid=\(handle.pid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)")
        case .none:
            Self.chipProbeLogger.info("postactivate-target no-eligible-candidate pid=\(handle.pid, privacy: .public)")
        }
        return verdict
    }

    private typealias GetProcessForPIDFunc =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let getProcessForPID: GetProcessForPIDFunc? = {
        let paths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            guard let get = dlsym(handle, "GetProcessForPID") else { continue }
            return unsafeBitCast(get, to: GetProcessForPIDFunc.self)
        }
        return nil
    }()

    func switchFrontmostForHandoff(toPID pid: pid_t, windowID: CGWindowID, awaitingDeactivationOf targetPID: pid_t,
                                   deactivationCap: TimeInterval = 0.1) -> Bool {
        let route: String
        if postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, mode: Self.kCPSNoWindows) {
            route = "skylight"
        } else if activateApplicationViaAccessibility(pid: pid) {
            route = "ax-frontmost"
        } else {
            Self.chipProbeLogger.info("switch-frontmost-handoff unavailable pid=\(pid, privacy: .public)")
            return false
        }
        let targetApp = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(targetApp, 0.05)
        let deadline = Date().addingTimeInterval(deactivationCap)
        var stillFrontmost: Bool? = true
        var lastAXError: Int32 = 0
        let waitStart = Date()
        repeat {
            var raw: CFTypeRef?
            let axError = AXUIElementCopyAttributeValue(targetApp, kAXFrontmostAttribute as CFString, &raw)
            if axError == .success {
                stillFrontmost = (raw as? NSNumber)?.boolValue
            } else {
                stillFrontmost = nil
                lastAXError = axError.rawValue
            }
            if stillFrontmost == false { break }
            usleep(2_000)
        } while Date() < deadline
        Self.chipProbeLogger.info("switch-frontmost-handoff pid=\(pid, privacy: .public) route=\(route, privacy: .public) targetStillFrontmost=\(String(describing: stillFrontmost), privacy: .public) axError=\(lastAXError, privacy: .public) waitMs=\(Int(Date().timeIntervalSince(waitStart) * 1000), privacy: .public)")
        return true
    }

    private func activateApplicationViaAccessibility(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    private typealias SLPSSetFrontWindowFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias SLPSPostEventFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

    private static let skyLightFocus: (slps: SLPSSetFrontWindowFunc, post: SLPSPostEventFunc)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let slps = dlsym(handle, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return (
            unsafeBitCast(slps, to: SLPSSetFrontWindowFunc.self),
            unsafeBitCast(post, to: SLPSPostEventFunc.self)
        )
    }()

    private static let skyLightFocusEnabled =
        DebugSwitch.skylightFocus.isEnabled(in: ProcessInfo.processInfo.environment)

    private static let serialNumbers = ProcessGenerationCache<ProcessSerialNumber>()

    private static func processSerialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let getPSN = getProcessForPID else { return nil }
        var psn = ProcessSerialNumber()
        if getPSN(pid, &psn) == noErr {
            serialNumbers.remember(psn, for: pid)
            return psn
        }
        return serialNumbers.value(for: pid)
    }

    fileprivate static let kCPSUserGenerated: UInt32 = 0x200
    fileprivate static let kCPSNoWindows: UInt32 = 0x400

    @discardableResult
    fileprivate func postSkyLightFrontSwitchOnly(
        pid: pid_t,
        windowID: CGWindowID,
        mode: UInt32 = AccessibilityWindowActionExecutor.kCPSUserGenerated
    ) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus, var psn = Self.processSerialNumber(for: pid) else { return false }
        _ = withUnsafePointer(to: &psn) { focus.slps($0, windowID, mode) }
        return true
    }

    @discardableResult
    fileprivate func postSkyLightWindowFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard Self.skyLightFocus != nil, Self.getProcessForPID != nil else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }
        guard postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, mode: Self.kCPSUserGenerated) else {
            Self.chipProbeLogger.info("skylight-focus GetProcessForPID failed pid=\(pid, privacy: .public)")
            return false
        }
        return postSkyLightMakeKeyDown(pid: pid, windowID: windowID)
    }

    @discardableResult
    fileprivate func postSkyLightMakeKeyDown(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus, var psn = Self.processSerialNumber(for: pid) else { return false }

        var event = [UInt8](repeating: 0, count: 0x100)
        event[0x04] = 0xf8            // 记录声明长度（不随缓冲区变）
        event[0x08] = 0x01            // kCGEventLeftMouseDown；只发 down，不发 up
        event[0x3a] = 0x10            // 用途未知；yabai / Hammerspoon / AltTab 均置 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { bytes in
            for index in 0..<4 {
                event[0x3c + index] = bytes[index]
            }
        }
        var offContentPoint = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &offContentPoint) { bytes in
            for index in 0..<16 {
                event[0x20 + index] = bytes[index]
            }
        }
        withUnsafePointer(to: &psn) { pointer in
            event.withUnsafeBufferPointer { _ = focus.post(pointer, $0.baseAddress!) }
        }
        return true
    }

    func makeKeyAfterHandoff(pid: pid_t, windowID: CGWindowID) {
        postSkyLightMakeKeyDown(pid: pid, windowID: windowID)
    }

    @discardableResult
    func focusWindowEarly(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        postSkyLightWindowFocus(pid: pid, windowID: cgWindowID)
    }

    @discardableResult
    func focusWindowViaSkyLight(pid: pid_t, element: AXUIElement) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let windowID = reader.cgWindowID(for: element) else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }

        guard postSkyLightWindowFocus(pid: pid, windowID: windowID) else {
            return false
        }
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return true
    }

    private func setMinimized(_ minimized: Bool, for handle: WindowHandle) -> Bool {
        reader.setMinimized(
            minimized,
            for: AXWindowHandle(pid: handle.pid, title: handle.title, bounds: handle.bounds, element: handle.element)
        )
    }

    private func bestMatch(for target: WindowTarget, from elements: [AXUIElement]) -> AXUIElement? {
        let scored = elements.compactMap { element -> (AXUIElement, Int)? in
            let title = axStringAttribute(kAXTitleAttribute as CFString, from: element)
            let bounds = axFrame(of: element)
            let score = AXWindowMatchPolicy.matchScore(
                targetTitle: target.title,
                targetBounds: target.bounds,
                candidateTitle: title,
                candidateBounds: bounds
            )
            return score.map { (element, $0) }
        }

        return scored.min(by: { $0.1 < $1.1 })?.0
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct ActionExecutionSwitches: Equatable {
    let fastWindowHandleEnabled: Bool
    let axElementCacheEnabled: Bool
    let chipProbeEnabled: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        fastWindowHandleEnabled = DebugSwitch.fastWindowHandle.isEnabled(in: environment)
        axElementCacheEnabled = DebugSwitch.axElementCache.isEnabled(in: environment)
        chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: environment)
    }
}

enum WindowHandleCapturePlan {
    static func capture<Handle>(
        cachedEnabled: Bool,
        fastEnabled: Bool,
        cgWindowID: CGWindowID?,
        justUnhid: Bool,
        cached: (CGWindowID) -> Handle?,
        fast: (CGWindowID) -> Handle?,
        fallback: () -> Handle?
    ) -> Handle? {
        if let cgWindowID, !justUnhid {
            if cachedEnabled, let handle = cached(cgWindowID) { return handle }
            if fastEnabled, let handle = fast(cgWindowID) { return handle }
        }
        return fallback()
    }

    static func usesAppFallbackAfterCaptureFailure(
        requestKind: PlatformActionRequest.ActionKind,
        isFinderWindow: Bool,
        knownMinimized: Bool
    ) -> Bool {
        requestKind == .activateWindow && !isFinderWindow && !knownMinimized
    }
}

enum MinimizedRestorePreActivation {
    static func canPreActivate(snapshot: DockSnapshot, target: WindowRecord) -> Bool {
        !snapshot.windows.values.contains {
            $0.pid == target.pid && $0.id != target.id && $0.status != .minimized
        }
    }
}

struct PlatformActionExecutor {
    private let windowExecutor: AccessibilityWindowActionExecutor
    private let switches: ActionExecutionSwitches
    private static let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")
    private static let postMinimizeActivateDelayMicroseconds: useconds_t = 50_000

    init(switches: ActionExecutionSwitches = ActionExecutionSwitches()) {
        self.switches = switches
        windowExecutor = AccessibilityWindowActionExecutor(chipProbeEnabled: switches.chipProbeEnabled)
    }

    @discardableResult
    func execute(
        _ request: PlatformActionRequest,
        snapshot: DockSnapshot,
        forcedMinimizedPrior: Bool,
        onHandoffActivePrediction: ((WindowID) -> Void)?
    ) -> Bool {
        guard let windowID = request.windowID,
              let record = snapshot.windows[windowID] else {
            return false
        }
        let effectiveKnownMinimized = forcedMinimizedPrior || record.status == .minimized

        guard !record.id.rawValue.hasPrefix("app-") else { return false }

        let isFinderWindow = FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier)

        if request.kind == .activateWindow,
           !forcedMinimizedPrior,
           let cgWindowID = record.cgWindowID,
           record.status == .active || record.status == .inactive,
           NSRunningApplication(processIdentifier: record.pid)?.isActive != true {
            windowExecutor.focusWindowEarly(pid: record.pid, cgWindowID: cgWindowID)
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "earlyFocus")
        }

        var justUnhid = false
        if isFinderWindow {
            let finderApp = NSRunningApplication(processIdentifier: record.pid)
            if finderApp?.isHidden == true {
                finderApp?.unhide()
                let deadline = Date().addingTimeInterval(0.2)
                while finderApp?.isHidden == true, Date() < deadline {
                    usleep(20_000)
                }
                justUnhid = true
            }
        }

        let target = AccessibilityWindowActionExecutor.WindowTarget(
            pid: record.pid, title: record.title, bounds: record.bounds)
        var captureTier = "none"
        let handle = WindowHandleCapturePlan.capture(
            cachedEnabled: switches.axElementCacheEnabled,
            fastEnabled: switches.fastWindowHandleEnabled,
            cgWindowID: record.cgWindowID,
            justUnhid: justUnhid,
            cached: {
                let h = windowExecutor.captureHandleFromCache(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds
                )
                if h != nil { captureTier = "cached" }
                return h
            },
            fast: {
                let h = windowExecutor.captureHandleByCGWindowID(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds
                )
                if h != nil { captureTier = "fast" }
                return h
            },
            fallback: {
                let h = windowExecutor.captureHandle(
                    for: target,
                    attempts: isFinderWindow ? 3 : 1,
                    retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
                )
                if h != nil { captureTier = "fallback" }
                return h
            }
        )
        ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "handle", detail: captureTier)

        guard let handle else {
            guard WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
                requestKind: request.kind,
                isFinderWindow: isFinderWindow,

                knownMinimized: effectiveKnownMinimized
            ) else {
                return false
            }
            return executeAppFallback(request: request, record: record)
        }

        switch request.kind {
        case .activateWindow:
            return windowExecutor.activate(
                handle,
                requiresFocusedConfirmation: isFinderWindow,
                knownCGWindowID: record.cgWindowID,
                knownMinimized: effectiveKnownMinimized,
                preActivateForRestore: effectiveKnownMinimized
                    && MinimizedRestorePreActivation.canPreActivate(snapshot: snapshot, target: record),
                awaitOnScreenBeforeFocus: forcedMinimizedPrior
            )
        case .minimizeWindow:
            let handoff = beginHandoff(handle: handle, record: record, snapshot: snapshot,
                                       onHandoffActivePrediction: onHandoffActivePrediction, patience: .minimize)
            let preSwitched = handoff.preSwitched

            func finishSuccessfulMinimize(_ exec: AccessibilityWindowActionExecutor.ActionExecution) -> Bool {
                finishHandoff(handoff)
                if switches.chipProbeEnabled {
                    Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(exec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(exec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: exec.verifiedMinimized), privacy: .public)")
                }
                return true
            }

            let minExec = windowExecutor.minimize(handle)
            if minExec.success {
                return finishSuccessfulMinimize(minExec)
            }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    let retryExec = windowExecutor.minimize(h)
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    return retryExec.success
                }
            }
            if minExec.verifiedMinimized != true {
                for attempt in 1...8 {
                    usleep(120_000)
                    let retryExec = windowExecutor.minimize(handle)
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-retry attempt=\(attempt, privacy: .public) windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    if retryExec.success {
                        return finishSuccessfulMinimize(retryExec)
                    }
                }
            }
            if switches.chipProbeEnabled {
                Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(minExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(minExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: minExec.verifiedMinimized), privacy: .public)")
            }
            return false
        case .closeWindow:
            let handoff = beginHandoff(handle: handle, record: record, snapshot: snapshot,
                                       onHandoffActivePrediction: onHandoffActivePrediction, patience: .close)
            if windowExecutor.close(handle) {
                finishHandoff(handoff)
                return true
            }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    return windowExecutor.close(h)
                }
            }
            return false
        }
    }

    private struct Handoff {
        var targetPID: pid_t?
        var windowID: CGWindowID?
        var preSwitched = false
    }

    struct HandoffPatience {
        let focusedReadBudget: TimeInterval
        let deactivationCap: TimeInterval
        static let minimize = HandoffPatience(focusedReadBudget: 0, deactivationCap: 0.1)
        static let close = HandoffPatience(focusedReadBudget: 0.5, deactivationCap: 0.5)
    }

    private func beginHandoff(
        handle: AccessibilityWindowActionExecutor.WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot,
        onHandoffActivePrediction: ((WindowID) -> Void)?,
        patience: HandoffPatience
    ) -> Handoff {
        let verdict = windowExecutor.findBackgroundActivationTarget(
            for: handle, record: record, snapshot: snapshot, focusedReadBudget: patience.focusedReadBudget
        )
        switch verdict {
        case .switchTo(_, _, let windowID), .siblingTakesOver(let windowID):
            onHandoffActivePrediction?(windowID)
        case .none:
            break
        }
        var handoff = Handoff()
        if case .switchTo(let pid, let wid, _) = verdict {
            handoff.targetPID = pid
            handoff.windowID = wid
            handoff.preSwitched = windowExecutor.switchFrontmostForHandoff(
                toPID: pid, windowID: wid, awaitingDeactivationOf: handle.pid,
                deactivationCap: patience.deactivationCap
            )
        }
        return handoff
    }

    private func finishHandoff(_ handoff: Handoff) {
        if handoff.preSwitched, let targetPID = handoff.targetPID, let handoffWindowID = handoff.windowID {
            windowExecutor.makeKeyAfterHandoff(pid: targetPID, windowID: handoffWindowID)
        }
        if !handoff.preSwitched, let targetPID = handoff.targetPID {
            usleep(Self.postMinimizeActivateDelayMicroseconds)
            let activated = NSRunningApplication(processIdentifier: targetPID)?
                .activate(options: [.activateIgnoringOtherApps]) ?? false
            if switches.chipProbeEnabled {
                Self.chipProbeLogger.info("postactivate-background-fallback pid=\(targetPID, privacy: .public) activated=\(activated, privacy: .public)")
            }
        }
    }

    private func executeAppFallback(request: PlatformActionRequest, record: WindowRecord) -> Bool {
        guard request.kind == .activateWindow else { return false }
        return windowExecutor.activateAppWithWindowRecovery(
            pid: record.pid, runningApp: NSRunningApplication(processIdentifier: record.pid))
    }

}

private func windows(for pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    guard let value = axCopyAttributeValue(kAXWindowsAttribute as CFString, from: appElement),
          let elements = value as? [AXUIElement] else {
        return []
    }
    return elements
}

private func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let text = value as? String else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func axBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let number = value as? NSNumber else {
        return nil
    }
    return number.boolValue
}

private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

private func axFrame(of element: AXUIElement) -> CGRect? {
    guard let positionAX = axCopyAttributeValue(kAXPositionAttribute as CFString, from: element),
          let sizeAX = axCopyAttributeValue(kAXSizeAttribute as CFString, from: element) else {
        return nil
    }

    guard CFGetTypeID(positionAX) == AXValueGetTypeID(),
          CFGetTypeID(sizeAX) == AXValueGetTypeID() else {
        return nil
    }
    let position = positionAX as! AXValue
    let sizeValueRef = sizeAX as! AXValue

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(position) == .cgPoint,
          AXValueGetType(sizeValueRef) == .cgSize,
          AXValueGetValue(position, .cgPoint, &point),
          AXValueGetValue(sizeValueRef, .cgSize, &size) else {
        return nil
    }

    return CGRect(origin: point, size: size)
}

private func axCopyAttributeValue(
    _ attribute: CFString,
    from element: AXUIElement,
    maxAttempts: Int = 2
) -> CFTypeRef? {
    var attempt = 0
    while attempt < maxAttempts {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .success {
            return value
        }

        if result != .cannotComplete {
            return nil
        }

        attempt += 1
        usleep(20_000)
    }

    return nil
}
