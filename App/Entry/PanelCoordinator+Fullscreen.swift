import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let screenCGFrame: CGRect?
}

extension PanelCoordinator {

    func setupFullscreenMonitor() {
        fullscreenProbeWorker = FullscreenProbeWorker(
            read: { Self.detectFullscreenViaAX(pid: $0.pid, screenCGFrame: $0.screenFrame) },
            deliver: { [weak self] request, result in self?.receiveFullscreenProbe(result, request: request) }
        )
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated { self?.handleAppActivated(pid: pid) }
        })
        lastActiveApplicationPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileFullscreenState() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
        triggerAsyncFullscreenCheck(source: "initial-ax")
    }

    private func handleSpaceChange() {
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay
        )
        let cgFullscreen = checkFullscreenViaCGSync()
        applyFullscreenVisibility(
            cgFullscreen,
            source: "space-cg",
            expectedSpaceHoldGeneration: spaceHoldGeneration
        )
        triggerAsyncFullscreenCheck(
            expectedSpaceHoldGeneration: spaceHoldGeneration,
            source: "space-ax"
        )
        repairAllSpacesMembershipIfNeeded()
    }

    private func handleAppActivated(pid: pid_t?) {
        lastActiveApplicationPID = pid
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        triggerAsyncFullscreenCheck(
            pid: lastActiveApplicationPID,
            expectedSpaceHoldGeneration: spaceHoldGeneration,
            source: "app-activation-ax"
        )
    }

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        guard let screen = panelCurrentScreen(panel: panel) else { return false }
        let screenCGFrame = Self.toCGRect(screen)
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let candidate = WindowLiftCGWindowProbe.frontmostLargeWindow(
            on: screenCGFrame,
            excludingPID: ourPID
        ) else { return false }

        let cgBounds = candidate.quartzFrame
        let t: CGFloat = 8
        return abs(cgBounds.width  - screenCGFrame.width)  < t
            && abs(cgBounds.height - screenCGFrame.height) < t
            && abs(cgBounds.minX   - screenCGFrame.minX)   < t
            && abs(cgBounds.minY   - screenCGFrame.minY)   < t
    }

    private func triggerAsyncFullscreenCheck(
        pid explicitPID: pid_t? = nil,
        expectedSpaceHoldGeneration explicitSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        source: String = "ax"
    ) {
        guard let screenCGFrame = currentPanelScreenCGFrame() else { return }
        let frontPID = explicitPID ?? lastActiveApplicationPID
        fullscreenProbeGeneration &+= 1
        let probeGeneration = fullscreenProbeGeneration
        let expectedSpaceHoldGeneration = explicitSpaceHoldGeneration ?? fullscreenSpaceHold?.generation
        fullscreenProbeWorker?.request(FullscreenProbeRequest(
            pid: frontPID, screenFrame: screenCGFrame, generation: probeGeneration,
            spaceGeneration: expectedSpaceHoldGeneration, finalConfirmation: isFinalSpaceHoldWindowedConfirmation, source: source
        ))
    }

    func receiveFullscreenProbe(_ probe: FullscreenAXProbe, request: FullscreenProbeRequest) {
        guard !isSuspendedForPermissionLoss, request.generation == fullscreenProbeGeneration else { return }
        let fullscreen: Bool
        let source: String
        switch probe.verdict {
        case .unknown:
            guard Self.slsVerdictEnabled, fullscreenVerdictFromSpaceLayout() == true else { return }
            fullscreen = true
            source = request.source + "-sls"
        case .fullscreen:
            fullscreen = true
            source = request.source
        case .windowed:
            fullscreen = Self.slsVerdictEnabled && fullscreenVerdictFromSpaceLayout() == true
            source = fullscreen ? request.source + "-sls" : request.source
        case .notOnThisScreen:
            guard Self.slsVerdictEnabled else {
                return
            }
            if let fromSpace = fullscreenVerdictFromSpaceLayout() {
                fullscreen = fromSpace
                source = request.source + "-sls"
            } else if request.finalConfirmation {
                fullscreen = checkFullscreenViaCGSync()
                source = request.source + "-cgfallback"
            } else { return }
        }
        applyFullscreenVisibility(fullscreen, source: source, expectedSpaceHoldGeneration: request.spaceGeneration,
                                  isFinalSpaceHoldWindowedConfirmation: request.finalConfirmation)
        reconcileOverlayWindowWatch(overlayWindowID: probe.overlayWindowID)
    }

    func windowGeometryChanged() {
        guard !isSuspendedForPermissionLoss else { return }
        triggerAsyncFullscreenCheck(source: "window-geometry-ax")
    }

    private func reconcileOverlayWindowWatch(overlayWindowID: CGWindowID?) {
        guard let overlayWindowID, visibilityState.hideReasons.contains(.fullscreen) else {
            endOverlayWindowWatch()
            return
        }
        beginOverlayWindowWatch(windowID: overlayWindowID)
    }

    private func beginOverlayWindowWatch(windowID: CGWindowID) {
        guard Self.overlayWindowWatchEnabled else { return }
        if overlayWindowWatchID == windowID, overlayWindowWatchTimer != nil { return }
        endOverlayWindowWatch()
        overlayWindowWatchID = windowID
        let timer = Timer(timeInterval: OverlayWindowWatch.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.overlayWindowWatchTick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        overlayWindowWatchTimer = timer
    }

    func endOverlayWindowWatch() {
        overlayWindowWatchTimer?.invalidate()
        overlayWindowWatchTimer = nil
        overlayWindowWatchID = nil
    }

    private func overlayWindowWatchTick() {
        guard let windowID = overlayWindowWatchID,
              visibilityState.hideReasons.contains(.fullscreen),
              let screenCGFrame = currentPanelScreenCGFrame() else {
            endOverlayWindowWatch()
            return
        }
        let observation = Self.cgWindowObservation(of: windowID)
        guard OverlayWindowWatch.shouldRecheck(
            isOnscreen: observation?.isOnscreen,
            bounds: observation?.bounds,
            screenCGFrame: screenCGFrame
        ) else { return }
        endOverlayWindowWatch()
        triggerAsyncFullscreenCheck(source: "overlay-gone-ax")
    }

    nonisolated private static func cgWindowObservation(of windowID: CGWindowID) -> (isOnscreen: Bool, bounds: CGRect?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return nil }
        let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return (isOnscreen, bounds)
    }

    func reconcileFullscreenState() {
        triggerAsyncFullscreenCheck(
            isFinalSpaceHoldWindowedConfirmation: fullscreenSpaceHold != nil && fullscreenSpaceHoldTimer == nil,
            source: "periodic-ax"
        )
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false
    ) {
        guard !isSuspendedForPermissionLoss else { return }
        switch FullscreenSpaceHoldDecision.disposition(
            isFullscreenVerdict: isFullscreen,
            expectedGeneration: expectedSpaceHoldGeneration,
            activeGeneration: fullscreenSpaceHold?.generation,
            isFinalWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation
        ) {
        case .stale, .hold:
            return
        case .apply:
            if let hold = fullscreenSpaceHold {
                finishFullscreenSpaceHold(generation: hold.generation)
            }
        }
        visibilityState.setFullscreen(isFullscreen)
        if isFullscreen { dismissTaskbarPopups() }
        diagnosticFullscreenSource = source
        diagnosticFullscreenVerdict = isFullscreen
        reconcilePanelVisibility()
        logFullscreenVerdict(isFullscreen, source: source)
    }

    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }

    @discardableResult
    private func beginFullscreenSpaceHold(
        pid: pid_t?,
        confirmationDelay: TimeInterval
    ) -> UInt64? {
        guard visibilityState.hideReasons.contains(.fullscreen) else {
            return nil
        }

        let screenCGFrame = currentPanelScreenCGFrame()
        let hold: FullscreenSpaceHold
        if let current = fullscreenSpaceHold,
           current.pid == pid,
           current.screenCGFrame == screenCGFrame {
            hold = current
        } else {
            fullscreenSpaceHoldGeneration &+= 1
            fullscreenProbeGeneration &+= 1
            hold = FullscreenSpaceHold(
                generation: fullscreenSpaceHoldGeneration,
                pid: pid,
                screenCGFrame: screenCGFrame
            )
            fullscreenSpaceHold = hold
        }
        scheduleFullscreenSpaceHoldConfirmation(
            generation: hold.generation,
            after: confirmationDelay
        )
        return hold.generation
    }

    private func scheduleFullscreenSpaceHoldConfirmation(
        generation: UInt64,
        after delay: TimeInterval
    ) {
        fullscreenSpaceHoldTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.confirmFullscreenSpaceHoldWindowed(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceHoldTimer = timer
    }

    private func confirmFullscreenSpaceHoldWindowed(generation: UInt64) {
        guard let hold = fullscreenSpaceHold,
              hold.generation == generation else {
            return
        }
        guard hold.pid == lastActiveApplicationPID,
              hold.screenCGFrame == currentPanelScreenCGFrame() else {
            finishFullscreenSpaceHold(generation: generation)
            triggerAsyncFullscreenCheck(pid: lastActiveApplicationPID)
            return
        }
        fullscreenSpaceHoldTimer = nil
        let cgFullscreen = checkFullscreenViaCGSync()
        triggerAsyncFullscreenCheck(
            pid: hold.pid,
            expectedSpaceHoldGeneration: generation,
            isFinalSpaceHoldWindowedConfirmation: true,
            source: cgFullscreen ? "space-hold-final-ax-cgtrue" : "space-hold-final-ax"
        )
    }

    private func finishFullscreenSpaceHold(generation: UInt64) {
        guard fullscreenSpaceHold?.generation == generation else { return }
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
    }

    func currentPanelScreenCGFrame() -> CGRect? {
        if let fullscreenFrameProvider { return fullscreenFrameProvider() }
        guard let panel = dockPanel else { return nil }
        return panelCurrentScreen(panel: panel).map(Self.toCGRect)
    }

    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> FullscreenAXProbe {
        guard let pid else { return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil) }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.1)

        var rawFocused: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawFocused)
        if focusedError == .noValue { return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil) }
        guard focusedError == .success, let rawFocused, CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            return FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }
        let focused = rawFocused as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(focused, 0.1)
        guard let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1) else {
            return FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }
        if role != kAXWindowRole { return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil) }
        var rawFullscreen: CFTypeRef?
        let fullscreenError = AXUIElementCopyAttributeValue(focused, "AXFullScreen" as CFString, &rawFullscreen)
        guard fullscreenError == .success || fullscreenError == .attributeUnsupported || fullscreenError == .noValue else {
            return FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }
        guard fullscreenError != .success || rawFullscreen is NSNumber else {
            return FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }
        let isAXFullscreen = (rawFullscreen as? NSNumber)?.boolValue ?? false
        guard let windowFrame = reader.frame(of: focused, maxAttempts: 1) else {
            return FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }
        let cgWindowID = isAXFullscreen ? nil : reader.cgWindowID(for: focused, maxAttempts: 1)
        let windowLayer = cgWindowID.flatMap(Self.cgWindowLayer(of:))

        let verdict = FullscreenWindowClassifier.classify(
            role: role,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            windowLayer: windowLayer,
            screenCGFrame: screenCGFrame
        )
        return FullscreenAXProbe(
            verdict: verdict,
            overlayWindowID: verdict == .fullscreen && !isAXFullscreen ? cgWindowID : nil
        )
    }

    nonisolated private static func cgWindowLayer(of windowID: CGWindowID) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return nil }
        return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private func fullscreenVerdictFromSpaceLayout() -> Bool? {
        if let fullscreenSpaceProvider { return fullscreenSpaceProvider() }
        guard let panel = dockPanel,
              let screen = panelCurrentScreen(panel: panel),
              let uuid = DisplayIdentity.uuidString(for: screen),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
        return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
    }
}
