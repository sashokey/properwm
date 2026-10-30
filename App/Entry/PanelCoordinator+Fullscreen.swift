import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

struct FullscreenIntentTransaction {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}
struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let screenCGFrame: CGRect?
}

extension PanelCoordinator {

    func setupFullscreenMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAppActivated(note) }
        })
        lastActiveApplicationPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fullscreenReconcileIfNeeded() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
    }

    func setFullscreenIntentRouting(enabled: Bool) {
        fullscreenIntentRoutingEnabled = enabled && !isSuspendedForPermissionLoss
        guard !fullscreenIntentRoutingEnabled else { return }
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "disabled")
        }
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "disabled")
        }
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
            expectedIntentGeneration: fullscreenIntentTransaction?.generation,
            pid: lastActiveApplicationPID,
            screenCGFrame: currentPanelScreenCGFrame(),
            expectedSpaceHoldGeneration: spaceHoldGeneration
        )
        if !cgFullscreen || fullscreenIntentTransaction == nil {
            triggerAsyncFullscreenCheck(
                expectedSpaceHoldGeneration: spaceHoldGeneration,
                source: "space-ax"
            )
        }
        repairAllSpacesMembershipIfNeeded()
    }

    private func handleAppActivated(_ note: Notification) {
        let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        lastActiveApplicationPID = activated?.processIdentifier
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        cancelFullscreenIntentIfContextChanged(activePID: activated?.processIdentifier)
        triggerAsyncFullscreenCheck(
            pid: lastActiveApplicationPID,
            expectedSpaceHoldGeneration: spaceHoldGeneration,
            source: "app-activation-ax"
        )
    }

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        let screen = panelCurrentScreen(panel: panel)
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
        isFinalSpaceIntentVerdict: Bool = false,
        source: String = "ax"
    ) {
        guard let panel = dockPanel else { return }
        let screenCGFrame = Self.toCGRect(panelCurrentScreen(panel: panel))
        let frontPID = explicitPID ?? lastActiveApplicationPID
        fullscreenProbeGeneration &+= 1
        let probeGeneration = fullscreenProbeGeneration
        let expectedIntentGeneration = fullscreenIntentTransaction?.generation
        let expectedSpaceHoldGeneration = explicitSpaceHoldGeneration ?? fullscreenSpaceHold?.generation
        Task.detached { [weak self] in
            let probe = Self.detectFullscreenViaAX(pid: frontPID, screenCGFrame: screenCGFrame)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard probeGeneration == self.fullscreenProbeGeneration else {
                    return
                }
                let verdict = probe.verdict
                let fullscreen: Bool
                let resolvedSource: String
                switch verdict {
                case .fullscreen:
                    fullscreen = true
                    resolvedSource = source
                case .windowed:
                    fullscreen = false
                    resolvedSource = source
                case .notOnThisScreen:
                    guard Self.slsVerdictEnabled else {
                        fullscreen = false
                        resolvedSource = source
                        break
                    }
                    if let fromSpace = self.fullscreenVerdictFromSpaceLayout() {
                        fullscreen = fromSpace
                        resolvedSource = "\(source)-sls"
                    } else if isFinalSpaceHoldWindowedConfirmation || isFinalSpaceIntentVerdict {
                        fullscreen = self.checkFullscreenViaCGSync()
                        resolvedSource = "\(source)-cgfallback"
                    } else {
                        return
                    }
                }
                self.applyFullscreenVisibility(
                    fullscreen,
                    source: resolvedSource,
                    expectedIntentGeneration: expectedIntentGeneration,
                    pid: frontPID,
                    screenCGFrame: screenCGFrame,
                    expectedSpaceHoldGeneration: expectedSpaceHoldGeneration,
                    isFinalSpaceHoldWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation,
                    isFinalSpaceIntentVerdict: isFinalSpaceIntentVerdict
                )
                self.reconcileOverlayWindowWatch(overlayWindowID: probe.overlayWindowID)
            }
        }
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

    private func fullscreenReconcileIfNeeded() {
        guard visibilityState.hideReasons.contains(.fullscreen) else { return }
        triggerAsyncFullscreenCheck()
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedIntentGeneration: UInt64? = nil,
        pid: pid_t? = nil,
        screenCGFrame: CGRect? = nil,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false
    ) {
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            if isFullscreen {
                guard visibilityState.confirmFullscreenTransition(generation: spaceGeneration) else {
                    return
                }
                clearFullscreenSpaceArrowIntent()
                fullscreenIntentLogger.notice(
                    "space-confirmed source=\(source, privacy: .public) generation=\(spaceGeneration, privacy: .public)"
                )
                dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
                diagnosticFullscreenSource = source
                diagnosticFullscreenVerdict = true
                reconcilePanelVisibility()
                logFullscreenVerdict(true, source: source)
                return
            }
            guard isFinalSpaceIntentVerdict else {
                if source == "space-cg" {
                    scheduleFullscreenSpaceIntentVerdict(generation: spaceGeneration)
                }
                return
            }
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "space-windowed")
        }
        switch FullscreenSpaceHoldDecision.disposition(
            isFullscreenVerdict: isFullscreen,
            expectedGeneration: expectedSpaceHoldGeneration,
            activeGeneration: fullscreenSpaceHold?.generation,
            isFinalWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation
        ) {
        case .stale:
            return
        case .hold:
            return
        case .apply:
            if let hold = fullscreenSpaceHold {
                finishFullscreenSpaceHold(generation: hold.generation)
            }
        }
        if isFullscreen {
            if let transaction = fullscreenIntentTransaction {
                guard expectedIntentGeneration == transaction.generation,
                      pid == transaction.pid,
                      screenCGFrame == transaction.screenCGFrame,
                      isFullscreenIntentContextCurrent(transaction),
                      visibilityState.confirmFullscreenTransition(generation: transaction.generation) else {
                    return
                }
                finishFullscreenIntentTransaction()
                fullscreenIntentLogger.notice(
                    "confirmed source=\(source, privacy: .public) generation=\(transaction.generation, privacy: .public)"
                )
            } else {
                visibilityState.setFullscreen(true)
            }
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        } else {
            if fullscreenIntentTransaction != nil { return }
            visibilityState.setFullscreen(false)
        }
        diagnosticFullscreenSource = source
        diagnosticFullscreenVerdict = isFullscreen
        reconcilePanelVisibility()
        logFullscreenVerdict(isFullscreen, source: source)
    }

    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        if reasons.contains(.fullscreenTransitionPending) { parts.append("pending") }
        if reasons.contains(.edgeAutoHide) { parts.append("edge") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }

    func beginFullscreenIntent(_ request: FullscreenIntentRequest) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              request.screenCGFrame == currentPanelScreenCGFrame(),
              lastActiveApplicationPID == request.pid else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenProbeGeneration &+= 1
        fullscreenIntentTransaction = FullscreenIntentTransaction(
            generation: generation,
            pid: request.pid,
            focusedWindowID: request.focusedWindowID,
            screenCGFrame: request.screenCGFrame
        )
        fullscreenIntentTimeoutTimer?.invalidate()
        visibilityState.beginFullscreenTransition(generation: generation)

        diagnosticFullscreenSource = request.source.rawValue + "-prediction"

        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        orderOutPanelsForFullscreenPrediction()
        fullscreenIntentLogger.notice(
            "pending source=\(request.source.rawValue, privacy: .public) generation=\(generation, privacy: .public) pid=\(request.pid, privacy: .public)"
        )

        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenIntentTimeoutTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenIntentTransaction?.generation == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    func cancelFullscreenIntent(generation: UInt64, reason: String) {
        guard fullscreenIntentTransaction?.generation == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        finishFullscreenIntentTransaction()
        fullscreenProbeGeneration &+= 1
        diagnosticFullscreenSource = "intent-cancel-" + reason
        fullscreenIntentLogger.notice(
            "cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    private func finishFullscreenIntentTransaction() {
        fullscreenIntentTransaction = nil
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
    }

    private func orderOutPanelsForFullscreenPrediction() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        dragController.cancelDrag()
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)

        noteVisibilityChange(visible: false, source: diagnosticFullscreenSource)
        lastHideWasForFullscreen = true
        orderDockSurfaceOut()
        windowTitleTooltipPanel?.orderOut(nil)
    }

    func beginFullscreenSpaceIntent(direction: SpaceSwitchDirection) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              fullscreenSpaceIntentGeneration == nil,
              !isSuspendedForPermissionLoss,
              !visibilityState.hideReasons.contains(.fullscreen) else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenSpaceIntentGeneration = generation
        fullscreenProbeGeneration &+= 1
        visibilityState.beginFullscreenTransition(generation: generation)

        diagnosticFullscreenSource = "space-intent-" + direction.rawValue

        noteVisibilityChange(visible: false, source: diagnosticFullscreenSource)
        lastHideWasForFullscreen = true
        let fadingPanels = [dockGlassBackgroundPanel, dockPanel].compactMap { $0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            for panel in fadingPanels { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.fullscreenSpaceIntentGeneration == generation else {
                    for panel in fadingPanels { panel.alphaValue = 1 }
                    return
                }
                self.orderOutPanelsForFullscreenPrediction()
                for panel in fadingPanels { panel.alphaValue = 1 }
            }
        })
        fullscreenIntentLogger.notice(
            "space-pending generation=\(generation, privacy: .public) direction=\(direction.rawValue, privacy: .public)"
        )

        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenSpaceArrowIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenSpaceIntentGeneration == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    private func cancelFullscreenSpaceArrowIntent(generation: UInt64, reason: String) {
        guard fullscreenSpaceIntentGeneration == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        clearFullscreenSpaceArrowIntent()
        fullscreenProbeGeneration &+= 1
        diagnosticFullscreenSource = "space-intent-cancel-" + reason
        fullscreenIntentLogger.notice(
            "space-cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    func clearFullscreenSpaceArrowIntent() {
        fullscreenSpaceIntentGeneration = nil
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentTimer = nil
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer = nil
    }

    private func scheduleFullscreenSpaceIntentVerdict(generation: UInt64) {
        guard fullscreenSpaceIntentVerdictTimer == nil else { return }
        let timer = Timer(
            timeInterval: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resolveFullscreenSpaceArrowIntent(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentVerdictTimer = timer
    }

    private func resolveFullscreenSpaceArrowIntent(generation: UInt64) {
        guard fullscreenSpaceIntentGeneration == generation else { return }
        fullscreenSpaceIntentVerdictTimer = nil
        if checkFullscreenViaCGSync() {
            applyFullscreenVisibility(true, source: "space-intent-delayed-cg")
            return
        }
        triggerAsyncFullscreenCheck(
            isFinalSpaceIntentVerdict: true,
            source: "space-intent-final-ax"
        )
    }

    @discardableResult
    private func beginFullscreenSpaceHold(
        pid: pid_t?,
        confirmationDelay: TimeInterval
    ) -> UInt64? {
        guard FullscreenSpaceHoldDecision.shouldBegin(
            isFullscreen: visibilityState.hideReasons.contains(.fullscreen),
            hasInputIntent: fullscreenIntentTransaction != nil || fullscreenSpaceIntentGeneration != nil
        ) else {
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

    func cancelFullscreenIntentIfContextChanged(activePID: pid_t? = nil) {
        guard let transaction = fullscreenIntentTransaction else { return }
        let currentPID = activePID ?? lastActiveApplicationPID
        guard currentPID != transaction.pid || currentPanelScreenCGFrame() != transaction.screenCGFrame else {
            return
        }
        cancelFullscreenIntent(generation: transaction.generation, reason: "context-changed")
    }

    private func isFullscreenIntentContextCurrent(_ transaction: FullscreenIntentTransaction) -> Bool {
        NSRunningApplication(processIdentifier: transaction.pid)?.isActive == true
            && currentPanelScreenCGFrame() == transaction.screenCGFrame
    }

    func handleFullscreenIntentContextChange(
        _ change: FullscreenIntentMonitor.ContextChange
    ) {
        if case let .activeApplication(pid) = change {
            lastActiveApplicationPID = pid
        }
        guard let transaction = fullscreenIntentTransaction else { return }
        switch change {
        case let .activeApplication(pid):
            if pid != transaction.pid {
                cancelFullscreenIntent(generation: transaction.generation, reason: "app-changed")
            }
        case .focusedWindow:
            cancelFullscreenIntent(generation: transaction.generation, reason: "focus-changed")
        case let .windowDestroyed(windowID):
            if windowID == nil || windowID == transaction.focusedWindowID {
                cancelFullscreenIntent(generation: transaction.generation, reason: "window-destroyed")
            }
        }
    }

    func currentPanelScreenCGFrame() -> CGRect? {
        guard let panel = dockPanel else { return nil }
        return Self.toCGRect(panelCurrentScreen(panel: panel))
    }

    struct FullscreenAXProbe {
        let verdict: FullscreenAXVerdict
        let overlayWindowID: CGWindowID?
    }

    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> FullscreenAXProbe {
        guard let pid else { return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil) }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let focused = reader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.5)

        let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1)
        let isAXFullscreen = reader.boolAttribute("AXFullScreen" as CFString, from: focused, maxAttempts: 1) ?? false
        let windowFrame = reader.frame(of: focused, maxAttempts: 1)
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
        guard let panel = dockPanel,
              let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: panel)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
        return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
    }
}
