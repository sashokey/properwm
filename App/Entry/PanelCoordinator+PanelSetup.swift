import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

extension PanelCoordinator {
    func setupDockPanel() {
        let screen = resolvedPinnedScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let s = screen.frame
        let legacyInitialFrame = NSRect(
            x: s.minX,
            y: s.minY + layoutMetrics.bottomGap - Self.shadowPadding,
            width: s.width,
            height: windowHeight
        )

        let glassBackground = makeTaskbarGlassBackground(contentPanelFrame: legacyInitialFrame)
        let usesLiquidGlass = glassBackground != nil

        let panel = makeFloatingPanel(contentRect: legacyInitialFrame, usesLiquidGlass: usesLiquidGlass)
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)

        let hosting = NSHostingView(rootView: DockStripView(
            usesLiquidGlass: usesLiquidGlass,
            stripSurfaceID: stripSurfaceID,
            displayUUID: fixedUnitDisplayUUID,
            onWindowTitleTooltipEvent: { [weak self] event in
                self?.handleWindowTitleTooltipEvent(event)
            },
            onRequestTaskbarMenu: { [weak self] event, view in
                self?.prepareResizeCursorForMenu()
                self?.onRequestTaskbarMenu?(event, view)
            },
            onInteractiveResize: { [weak self] event in
                switch event {
                case let .pointerEnteredBar(hitTest): self?.assertBarArrowCursor(hitTest: hitTest)
                case let .hover(pointer): self?.gripHoverChanged(pointer)
                case let .began(pointer): self?.beginInteractiveResize(pointer: pointer)
                case let .changed(pointer): self?.updateInteractiveResize(pointer: pointer)
                case .ended: self?.endInteractiveResize()
                }
            },
            resizeGripController: resizeGripController,
            onLabelWidthChange: { [weak self] starting in self?.beginLabelWidthFollow(starting: starting) },
            onLabelBoxWidthTick: { [weak self] id, width in self?.labelBoxWidthDidTick(chipID: id, width: width) }
        ).environmentObject(runtime).environmentObject(stripOrderStore).environmentObject(dragController).environmentObject(settingsStore).environmentObject(displayTopologyStore)
            .modifier(PanelHeightResizeModifier(presentation: heightResizePresentation)))
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        dockContentHost = ManualPanelHost(contentView: hosting, in: panel)
        dockPanel = panel

        if let (backgroundPanel, backgroundView) = glassBackground {
            dockGlassBackgroundPanel = backgroundPanel
            dockGlassBackgroundView = backgroundView
        }
    }

    private func makeTaskbarGlassBackground(
        contentPanelFrame: NSRect
    ) -> (NonConstrainingPanel, DockTaskbarLiquidGlassBackgroundView)? {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return nil }

        let configuration = DockGlassPresentation.configuration
        let backgroundFrame = DockLiquidGlassPanelGeometry.backgroundFrame(
            for: contentPanelFrame,
            shadowPadding: Self.shadowPadding
        )
        guard backgroundFrame.width > 0, backgroundFrame.height > 0 else { return nil }

        let panel = NonConstrainingPanel(
            contentRect: backgroundFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let backgroundView = DockTaskbarLiquidGlassBackgroundView(
            frame: NSRect(origin: .zero, size: backgroundFrame.size),
            cornerRadius: taskbarPlateCornerRadius,
            configuration: configuration
        )
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        if let blurRadius = configuration.requestedWindowBlurRadius,
           !TEDockGlassSetWindowBackgroundBlurRadius(panel.windowNumber, blurRadius) {
            print("[glass] window blur radius \(blurRadius) rejected by WindowServer; continuing without it")
        }
        return (panel, backgroundView)
    }

    func tearDownTaskbarGlassBackground() {
        guard let background = dockGlassBackgroundPanel else { return }
        if DockGlassPresentation.configuration.requestedWindowBlurRadius != nil {
            _ = TEDockGlassSetWindowBackgroundBlurRadius(background.windowNumber, 0)
        }
        background.contentView = nil
        background.orderOut(nil)
        background.close()
        dockGlassBackgroundView = nil
        dockGlassBackgroundPanel = nil
    }

    func orderDockSurfaceFront() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: true
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderFrontRegardless()
            case .content:
                dockPanel?.orderFrontRegardless()
            }
        }
        if let background = dockGlassBackgroundPanel, let dock = dockPanel {
            background.order(.below, relativeTo: dock.windowNumber)
        }
    }

    func orderDockSurfaceOut() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: false
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderOut(nil)
            case .content:
                dockPanel?.orderOut(nil)
            }
        }
    }

    func presentInitialPanels() {
        guard let dock = dockPanel else { return }
        dock.layoutIfNeeded()
        relayout(animated: false)
        orderDockSurfaceFront()
    }

    func makeFloatingPanel(contentRect: NSRect, usesLiquidGlass: Bool) -> NonConstrainingPanel {
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        return usesLiquidGlass
            ? DockLiquidGlassPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
            : NonConstrainingPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
    }

    func configurePanel(_ panel: NSPanel, backgroundColor: NSColor, appliesLevelOverride: Bool) {
        panel.level = .floating
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        if appliesLevelOverride, let level = Self.panelLevelOverride { panel.level = level }
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = backgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
    }
}
