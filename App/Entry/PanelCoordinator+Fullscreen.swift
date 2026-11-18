import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
#if DEBUG
import os
#endif

struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let screenCGFrame: CGRect?
}

extension PanelCoordinator {

    func setupFullscreenMonitor() {
        let readsSpaces = Self.slsVerdictEnabled
        let readSpace = fullscreenSpaceProvider ?? { uuid in
            guard let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
            return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
        }
        fullscreenProbeWorker = FullscreenProbeWorker(
            read: { request in
                let observation = request.sharedRead?.observation(for: request.pid)
                    ?? request.pid.map(Self.readFullscreenAXObservation) ?? .unknown
                return observation.probe(on: request.screenFrame)
            },
            readSpace: { request in
                guard readsSpaces, let uuid = request.displayUUID else { return nil }
                return readSpace(uuid)
            },
            deliver: { [weak self] request, result in self?.receiveFullscreenProbe(result, request: request) }
        )
        lastActiveApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if !usesSharedFullscreenMonitor { startLocalFullscreenMonitor() }
        triggerAsyncFullscreenCheck(source: "initial-ax")
    }

    private func startLocalFullscreenMonitor() {
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
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileFullscreenState() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
    }

    func handleSpaceChange(
        sharedRead: FullscreenAXReadBatch? = nil,
        readCGWindows: (() -> [[String: Any]]?)? = nil
    ) {
        guard !isSuspendedForPermissionLoss else { return }
        taskbarView?.taskbarContent.prepareForHiding()
        overlaySpaceHost?.reconcileVisibility()
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay
        )
        let cgFullscreen = checkFullscreenViaCGSync(readCGWindows: readCGWindows ?? readFullscreenCGWindows)
        applyFullscreenVisibility(
            cgFullscreen,
            source: "space-cg",
            expectedSpaceHoldGeneration: spaceHoldGeneration
        )
        triggerAsyncFullscreenCheck(source: "space-ax", sharedRead: sharedRead)
        repairAllSpacesMembershipIfNeeded()
    }

    func handleAppActivated(pid: pid_t?, sharedRead: FullscreenAXReadBatch? = nil) {
        lastActiveApplicationPID = pid
        beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        triggerAsyncFullscreenCheck(source: "app-activation-ax", sharedRead: sharedRead)
    }

    private func checkFullscreenViaCGSync(readCGWindows: () -> [[String: Any]]?) -> Bool {
        guard let screenCGFrame = currentPanelScreenCGFrame(),
              !screenCGFrame.isEmpty, !screenCGFrame.isInfinite,
              let windows = readCGWindows(),
              let candidate = WindowLiftCGWindowProbe.frontmostLargeWindow(
                  in: windows, on: screenCGFrame, excludingPID: ProcessInfo.processInfo.processIdentifier
              ) else { return false }

        return FullscreenWindowClassifier.matchesScreenFrame(candidate.quartzFrame, screenCGFrame)
    }

    nonisolated static func captureFullscreenCGWindows() -> [[String: Any]]? {
        NativeWindowSystem().windowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    }

    private func readFullscreenCGWindows() -> [[String: Any]]? {
        (fullscreenCGWindowsProvider ?? Self.captureFullscreenCGWindows)()
    }

    private func cgConfirmsWindowedScreen(for request: FullscreenProbeRequest) -> Bool {
        guard request.finalConfirmation, request.spaceGeneration != nil, let displayUUID = request.displayUUID,
              !request.screenFrame.isEmpty, !request.screenFrame.isInfinite else { return false }
        if let panel = dockPanel {
            guard let screen = panelCurrentScreen(panel: panel),
                  DisplayIdentity.uuidString(for: screen) == displayUUID else { return false }
        }
        guard let windows = readFullscreenCGWindows() else { return false }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            if (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ourPID { continue }
            if let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer < 0 { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            guard let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  !bounds.isNull, !bounds.isInfinite,
                  !FullscreenWindowClassifier.matchesScreenFrame(bounds, request.screenFrame) else { return false }
        }
        return true
    }

    private func triggerAsyncFullscreenCheck(
        source: String = "ax",
        sharedRead: FullscreenAXReadBatch? = nil
    ) {
        guard let screenCGFrame = currentPanelScreenCGFrame() else { return }
        let frontPID = lastActiveApplicationPID
        if let hold = fullscreenSpaceHold, fullscreenSpaceHoldTimer == nil,
           (hold.pid != frontPID || hold.screenCGFrame != screenCGFrame) {
            finishFullscreenSpaceHold(generation: hold.generation)
        }
        fullscreenProbeGeneration &+= 1
        let holdGeneration = fullscreenSpaceHold?.generation
        fullscreenProbeWorker?.request(FullscreenProbeRequest(
            pid: frontPID, screenFrame: screenCGFrame, generation: fullscreenProbeGeneration,
            spaceGeneration: holdGeneration, finalConfirmation: holdGeneration != nil && fullscreenSpaceHoldTimer == nil,
            source: source, displayUUID: currentPanelDisplayUUID(), sharedRead: sharedRead
        ))
    }

    func receiveFullscreenProbe(_ probe: FullscreenAXProbe, request: FullscreenProbeRequest) {
        guard !isSuspendedForPermissionLoss, request.generation == fullscreenProbeGeneration,
              request.spaceGeneration == fullscreenSpaceHold?.generation,
              request.screenFrame == currentPanelScreenCGFrame() else { return }
        if let displayUUID = request.displayUUID {
            guard displayUUID == currentPanelDisplayUUID() else { return }
        }
        let fullscreen: Bool
        let source: String
        switch probe.verdict {
        case .unknown:
            guard Self.slsVerdictEnabled, let spaceVerdict = probe.spaceVerdict,
                  spaceVerdict || cgConfirmsWindowedScreen(for: request) else { return }
            fullscreen = spaceVerdict
            source = request.source + (spaceVerdict ? "-sls" : "-sls-cg")
        case .fullscreen:
            fullscreen = true
            source = request.source
        case .windowed:
            fullscreen = Self.slsVerdictEnabled && probe.spaceVerdict == true
            source = fullscreen ? request.source + "-sls" : request.source
        case .notOnThisScreen:
            guard Self.slsVerdictEnabled else {
                return
            }
            if let fromSpace = probe.spaceVerdict {
                fullscreen = fromSpace
                source = request.source + "-sls"
            } else if request.finalConfirmation {
                fullscreen = checkFullscreenViaCGSync(readCGWindows: readFullscreenCGWindows)
                source = request.source + "-cgfallback"
            } else { return }
        }
        applyFullscreenVisibility(fullscreen, source: source, expectedSpaceHoldGeneration: request.spaceGeneration,
                                  isFinalSpaceHoldWindowedConfirmation: request.finalConfirmation)
        reconcileOverlayWindowWatch(overlayWindowID: probe.overlayWindowID)
    }

    func windowGeometryChanged(sharedRead: FullscreenAXReadBatch? = nil) {
        guard !isSuspendedForPermissionLoss else { return }
        triggerAsyncFullscreenCheck(source: "window-geometry-ax", sharedRead: sharedRead)
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
        guard let info = NativeWindowSystem().windowDescriptions(for: [windowID])?.first else { return nil }
        let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return (isOnscreen, bounds)
    }

    func reconcileFullscreenState(sharedRead: FullscreenAXReadBatch? = nil) {
        triggerAsyncFullscreenCheck(source: "periodic-ax", sharedRead: sharedRead)
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false
    ) {
        guard !isSuspendedForPermissionLoss else { return }
        switch FullscreenSpaceHoldDecision.disposition(
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
        reconcilePanelVisibility()
        #if DEBUG
        logFullscreenVerdict(isFullscreen, source: source)
        #endif
    }

    #if DEBUG
    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }
    #endif

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
            MainActor.assumeIsolated {
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
            triggerAsyncFullscreenCheck()
            return
        }
        fullscreenSpaceHoldTimer = nil
        triggerAsyncFullscreenCheck(source: "space-hold-final-ax")
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

    nonisolated static func readFullscreenAXObservation(pid: pid_t) -> FullscreenAXObservation {
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.1)

        var rawFocused: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawFocused)
        guard focusedError == .success, let rawFocused, CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let focused = rawFocused as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(focused, 0.1)
        guard let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1),
              role == kAXWindowRole else {
            return .unknown
        }
        var rawFullscreen: CFTypeRef?
        let fullscreenError = AXUIElementCopyAttributeValue(focused, "AXFullScreen" as CFString, &rawFullscreen)
        guard fullscreenError == .success || fullscreenError == .attributeUnsupported || fullscreenError == .noValue else {
            return .unknown
        }
        guard fullscreenError != .success || rawFullscreen is NSNumber else {
            return .unknown
        }
        let isAXFullscreen = (rawFullscreen as? NSNumber)?.boolValue ?? false
        guard let windowFrame = reader.frame(of: focused, maxAttempts: 1) else {
            return .unknown
        }
        let cgWindowID = isAXFullscreen ? nil : reader.cgWindowID(for: focused, maxAttempts: 1)
        let windowLayer = cgWindowID.flatMap(Self.cgWindowLayer(of:))

        return .window(role: role, isFullscreen: isAXFullscreen, frame: windowFrame, id: cgWindowID, layer: windowLayer)
    }

    nonisolated private static func cgWindowLayer(of windowID: CGWindowID) -> Int? {
        guard let info = NativeWindowSystem().windowDescriptions(for: [windowID])?.first else { return nil }
        return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private func currentPanelDisplayUUID() -> String? {
        if let fixedUnitDisplayUUID { return fixedUnitDisplayUUID }
        guard let panel = dockPanel, let screen = panelCurrentScreen(panel: panel) else { return nil }
        return DisplayIdentity.uuidString(for: screen)
    }
}
