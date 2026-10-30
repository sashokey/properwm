import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

extension PanelCoordinator {
    func handleWindowTitleTooltipEvent(_ event: WindowTitleTooltipEvent) {
        switch event {
        case let .update(request):
            if windowTitleTooltipSuppressedChipID == request.chipID { return }
            windowTitleTooltipSuppressedChipID = nil
            windowTitleTooltipSuppressedRequest = nil
            cancelWindowTitleTooltipLinger()

            HoverTrace.hover(chipID: request.chipID, entered: true)
            windowTitleTooltipRequest = request
            installWindowTitleTooltipMouseMonitors()
            presentWindowTitleTooltip(request)

        case let .exit(chipID):
            HoverTrace.hover(chipID: chipID, entered: false)
            if windowTitleTooltipSuppressedChipID == chipID {
                windowTitleTooltipSuppressedChipID = nil
                windowTitleTooltipSuppressedRequest = nil
            }
            guard windowTitleTooltipRequest?.chipID == chipID else { return }
            if isPointInsideTaskbarPanels(NSEvent.mouseLocation) {
                scheduleWindowTitleTooltipLinger()
            } else {
                dismissWindowTitleTooltip()
            }
        }
    }

    private func scheduleWindowTitleTooltipLinger() {
        cancelWindowTitleTooltipLinger()
        let timer = Timer(timeInterval: Self.windowTitleTooltipLingerDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowTitleTooltipLingerTimer = nil
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipLingerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelWindowTitleTooltipLinger() {
        windowTitleTooltipLingerTimer?.invalidate()
        windowTitleTooltipLingerTimer = nil
    }

    func startWindowTitleTooltipWatchdog() {
        guard windowTitleTooltipWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.windowTitleTooltipPanel?.isVisible == true,
                      self.windowTitleTooltipRequest != nil else {
                    self.stopWindowTitleTooltipWatchdog()
                    return
                }
                guard !self.isPointInsideTaskbarPanels(NSEvent.mouseLocation) else { return }
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func isPointInsideTaskbarPanels(_ point: CGPoint) -> Bool {
        dockPanel?.frame.contains(point) ?? false
    }

    private func stopWindowTitleTooltipWatchdog() {
        windowTitleTooltipWatchdog?.invalidate()
        windowTitleTooltipWatchdog = nil
    }

    private func presentWindowTitleTooltip(_ request: WindowTitleTooltipRequest) {
        guard request.anchorVisibleRect != .zero else { return }
        onAccessoryWillOpen?(self, .tooltip)
        let traceStart = CACurrentMediaTime()
        let traceCold = windowTitleTooltipPanel?.isVisible != true
        defer { HoverTrace.present(chipID: request.chipID, cold: traceCold,
                                   elapsed: CACurrentMediaTime() - traceStart) }
        let panel: NSPanel
        if let existing = windowTitleTooltipPanel {
            panel = existing
        } else {
            let created = makeFloatingPanel(contentRect: .zero, usesLiquidGlass: usesLiquidGlass)
            configurePanel(created, backgroundColor: .clear, appliesLevelOverride: false)
            created.ignoresMouseEvents = true
            windowTitleTooltipPanel = created
            panel = created
        }

        let style = WindowTitleTooltipStyle.native
        let contentHost: ManualPanelHost
        if let hosting = windowTitleTooltipHosting, let existingHost = windowTitleTooltipHost {
            hosting.rootView = WindowTitleTooltipView(title: request.title, style: style,
                                                    usesLiquidGlass: usesLiquidGlass)
            contentHost = existingHost
        } else {
            let hosting = NSHostingView(rootView: WindowTitleTooltipView(title: request.title, style: style,
                                                          usesLiquidGlass: usesLiquidGlass))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            contentHost = ManualPanelHost(contentView: hosting, in: panel)
            windowTitleTooltipHosting = hosting
            windowTitleTooltipHost = contentHost
        }
        panel.layoutIfNeeded()
        let size = contentHost.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let anchorPoint = CGPoint(x: request.anchorVisibleRect.midX, y: request.anchorVisibleRect.midY)
        let dockScreen = dockPanel.map { panelCurrentScreen(panel: $0) }
        if let dockScreen, !dockScreen.frame.contains(anchorPoint) { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? dockScreen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let target = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: request.anchorVisibleRect,
            size: size,
            tipGap: style.tipGap,
            on: Self.screenGeometry(screen)
        )
        panel.setFrame(target, display: true)

        panel.alphaValue = 1
        if panel.level != .floating { panel.level = .floating }
        if !panel.isVisible { panel.orderFrontRegardless() }
        pinOverlappingPanelIfNeeded(panel)
        startWindowTitleTooltipWatchdog()
    }

    private func installWindowTitleTooltipMouseMonitors() {
        guard windowTitleTooltipLocalMonitor == nil, windowTitleTooltipGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        windowTitleTooltipLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissWindowTitleTooltipOnMouseDown(event.type)
            return event
        }
        windowTitleTooltipGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissWindowTitleTooltipOnMouseDown(event.type)
        }
    }

    private func dismissWindowTitleTooltipOnMouseDown(_ type: NSEvent.EventType) {
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
    }

    func dismissWindowTitleTooltip(suppressCurrentUntilExit: Bool = false) {
        if suppressCurrentUntilExit, let request = windowTitleTooltipRequest {
            windowTitleTooltipSuppressedChipID = request.chipID
            windowTitleTooltipSuppressedRequest = request
        }
        cancelWindowTitleTooltipLinger()
        stopWindowTitleTooltipWatchdog()
        windowTitleTooltipRequest = nil
        if let monitor = windowTitleTooltipLocalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipLocalMonitor = nil
        }
        if let monitor = windowTitleTooltipGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipGlobalMonitor = nil
        }
        windowTitleTooltipPanel?.alphaValue = 0
        windowTitleTooltipPanel?.orderOut(nil)
    }
}
