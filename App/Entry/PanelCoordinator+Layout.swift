import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

extension PanelCoordinator {

    func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                let ids = Set(snapshot.orderedWindowIDs)
                let idsChanged = self.lastSnapshotWindowIDs != ids
                self.lastSnapshotWindowIDs = ids
                if idsChanged {
                    self.relayout(animated: true)   // layoutPanels 内含抽屉重定位
                } else if !self.isLabelFollowActive {
                    self.relayout(animated: true)
                }
            }
    }

    func subscribeSettings() {
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        dockPanelHeightSubscription = heightResizePresentation
            .nonInteractiveHeightChanges(from: settingsStore.$dockPanelHeight)
            .sink { [weak self] _ in
                self?.beginPanelHeightChange()
            }
    }

    func beginPanelHeightChange() {
        tearDownForPanelHeightChange()
        let generation = panelHeightChangeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.panelHeightChangeGeneration else { return }
            self.relayout(animated: false)
        }
    }

    func tearDownForPanelHeightChange() {
        panelHeightChangeGeneration &+= 1
        cancelLabelWidthFollow()
        dragController.cancelDrag()
        dismissWindowTitleTooltip()
    }

    func setInteractiveHeightResizeActive(_ active: Bool) {
        guard interactiveHeightResizeActive != active else { return }
        interactiveHeightResizeActive = active
        heightResizePresentation.isActive = active
        if active {
            liftContextPanelHeightOverride = layoutMetrics.panelHeight
            tearDownForPanelHeightChange()
            settleRunningFrameAnimation()
            relayout(animated: false, batched: true)
        } else {
            liftContextPanelHeightOverride = nil
            relayout(animated: false)
        }
    }

    func beginInteractiveResize(pointer: CGPoint) {
        guard interactiveResize == nil else { return }
        interactiveResize = DockHeightDragSession(startHeight: settingsStore.dockPanelHeight.points,
                                                  startPointerY: pointer.y)
        showResizeCursor(at: pointer)
        setAutoHideInhibitor(.interactiveResize, active: true)
        onInteractiveHeightResizeSession?(true)
        if !interactiveHeightResizeActive { setInteractiveHeightResizeActive(true) }
    }

    func updateInteractiveResize(pointer: CGPoint) {
        guard let session = interactiveResize else { return }
        showResizeCursor(at: pointer)
        let target = session.height(forPointerY: pointer.y)
        guard target != settingsStore.dockPanelHeight else { return }
        settingsStore.setDockPanelHeight(target)
        if let onInteractiveHeightResizeUpdate {
            onInteractiveHeightResizeUpdate()
        } else {
            commitInteractivePanelHeight()
        }
    }

    func commitInteractivePanelHeight() {
        guard interactiveHeightResizeActive else { return }
        panelHeightChangeGeneration &+= 1
        relayout(animated: false, batched: true)
    }

    func endInteractiveResize() {
        guard interactiveResize != nil else { return }
        interactiveResize = nil
        setAutoHideInhibitor(.interactiveResize, active: false)
        onInteractiveHeightResizeSession?(false)
        if interactiveHeightResizeActive { setInteractiveHeightResizeActive(false) }
    }

    func cancelInteractiveResize() {
        guard interactiveResize != nil else { return }
        resizeGripController.cancel()
        endInteractiveResize()
    }

    func settleRunningFrameAnimation() {
        guard CACurrentMediaTime() < animatedFramesUntil else { return }
        lastCommittedFrames = []
        relayout(animated: false)
    }

    func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool, batched: Bool = false) {
        guard let dock = dockPanel else { return }
        let panelScreenCGFrame = Self.toCGRect(screen)
        if let transaction = fullscreenIntentTransaction,
           transaction.screenCGFrame != panelScreenCGFrame {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        let anim = animated && didInitialLayout && !interactiveHeightResizeActive
        didInitialLayout = true
        onPanelScreenChanged?()

        let dockT = dockTargetFrame(contentWidth: contentWidth, on: screen)
        if dockT != lastDockTargetFrame {
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
        lastDockTargetFrame = dockT

        var pairs: [(NSPanel, NSRect)] = []
        if let background = dockGlassBackgroundPanel {
            dockGlassBackgroundView?.apply(
                cornerRadius: taskbarPlateCornerRadius,
                configuration: DockGlassPresentation.configuration
            )
            pairs.append((
                background,
                DockLiquidGlassPanelGeometry.backgroundFrame(
                    for: dockT,
                    shadowPadding: Self.shadowPadding
                )
            ))
        }
        pairs.append((dock, dockT))
        setFrames(pairs, animated: anim, batched: batched)
    }

    func relayout(animated: Bool, batched: Bool = false) {
        guard let panel = dockPanel, let hosting = dockContentHost else { return }
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("relayout", since: spanStart) }
        if interactiveHeightResizeActive {
            panel.disableScreenUpdatesUntilFlush()
            dockGlassBackgroundPanel?.disableScreenUpdatesUntilFlush()
            hosting.layoutContent()
        }
        let measureStart = CACurrentMediaTime()
        let measured = hosting.fittingSize.width - 2 * Self.shadowPadding
        HoverTrace.relayout(measureMs: CACurrentMediaTime() - measureStart,
                            width: measured,
                            changed: measured != lastDesiredWidth,
                            animated: animated,
                            timing: (isLabelFollowActive ? "follow" : "standard") + ":" + String(stripSurfaceID.suffix(4)))
        lastDesiredWidth = measured
        layoutPanels(contentWidth: measured, on: panelCurrentScreen(panel: panel), animated: animated,
                     batched: batched || interactiveHeightResizeActive)
        if interactiveHeightResizeActive {
            panel.layoutIfNeeded()
            hosting.layoutContent()
        }
    }

    enum FrameCommit { case unchanged, instant, animated }

    @discardableResult
    func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool, batched: Bool = false) -> FrameCommit {
        let targets = pairs.map(\.1)
        guard targets != lastCommittedFrames else {
            HoverTrace.framesUnchanged()
            return .unchanged
        }
        lastCommittedFrames = targets
        guard animated else {
            if CACurrentMediaTime() < animatedFramesUntil {
                animatedFramesUntil = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    for (p, f) in pairs { p.animator().setFrame(f, display: !batched) }
                }
            } else {
                for (p, f) in pairs { p.setFrame(f, display: !batched) }
            }
            if let dock = dockPanel { HoverTrace.width("panel:" + String(stripSurfaceID.suffix(4)), dock.frame.width) }
            return .instant
        }
        animatedFramesUntil = CACurrentMediaTime() + Self.layoutAnimationDuration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
        return .animated
    }

    var isLabelFollowActive: Bool { labelFollowTimer != nil }

    func beginLabelWidthFollow(starting: [String: CGFloat]) {
        guard !interactiveHeightResizeActive else { return }   // the drag owns the panel frames
        let now = CACurrentMediaTime()
        if !isLabelFollowActive {
            labelFollowRestWidth = lastDesiredWidth
            labelBoxStart = [:]
            labelBoxLive = [:]
        }
        for (id, from) in starting where labelBoxStart[id] == nil {
            labelBoxStart[id] = from
            labelBoxLive[id] = from
        }
        labelFollowDeadline = now + LabelWidthAnimation.curve.duration + 0.1
        guard labelFollowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard CACurrentMediaTime() >= self.labelFollowDeadline else { return }
            t.invalidate()
            self.labelFollowTimer = nil
            self.labelBoxStart = [:]
            self.labelBoxLive = [:]
            self.relayout(animated: false)   // 收尾量一次终值，吃掉起始宽估算的零点几 pt
        }
        RunLoop.main.add(timer, forMode: .common)
        labelFollowTimer = timer
    }

    func cancelLabelWidthFollow() {
        guard isLabelFollowActive else { return }
        labelFollowTimer?.invalidate()
        labelFollowTimer = nil
        labelBoxStart = [:]
        labelBoxLive = [:]
    }

    func labelBoxWidthDidTick(chipID: String, width: CGFloat) {
        guard !interactiveHeightResizeActive else { return }
        guard isLabelFollowActive, labelBoxStart[chipID] != nil, labelBoxLive[chipID] != width else { return }
        labelBoxLive[chipID] = width
        guard CACurrentMediaTime() >= animatedFramesUntil, let panel = dockPanel else { return }
        let delta = labelBoxStart.reduce(CGFloat(0)) { acc, entry in
            acc + ((labelBoxLive[entry.key] ?? entry.value) - entry.value)
        }
        layoutPanels(contentWidth: labelFollowRestWidth + delta,
                     on: panelCurrentScreen(panel: panel), animated: false, batched: true)
    }

    func screenParametersChanged() {
        cancelHoverSwitch()
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        guard dockPanel != nil else { return }
        if let home = resolvedPinnedScreen(), let panel = dockPanel,
           panelCurrentScreen(panel: panel) != home {
            layoutPanels(contentWidth: lastDesiredWidth, on: home, animated: false)
        }
        relayout(animated: false)      // 切屏瞬时,不滑
        cancelFullscreenIntentIfContextChanged()
        reconcilePanelVisibility()
    }

    static func screenGeometry(_ screen: NSScreen) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
    }
}
