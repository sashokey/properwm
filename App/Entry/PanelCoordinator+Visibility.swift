import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

extension PanelCoordinator {
    func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedDisplayUUID else { return nil }
        let screens = NSScreen.screens
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: pinnedUUID,
            screenUUIDs: screens.map { DisplayIdentity.uuidString(for: $0) },
            mainIndex: NSScreen.main.flatMap { screens.firstIndex(of: $0) }
        )
        switch outcome {
        case .matched(let index), .fallback(let index):
            return screens[index]
        case nil:
            return nil
        }
    }

    func setTaskbarMenuOpen(_ open: Bool) {
        isTaskbarMenuOpen = open
        resizeCursorMenuVisibilityChanged(open)
    }

    func reconcilePanelVisibility() {
        applyPanelVisibility()
    }

    func applyPanelVisibility() {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible
        guard shouldShow != panelsAreVisible else { return }
        noteVisibilityChange(visible: shouldShow, source: diagnosticFullscreenSource)
        if shouldShow {
            let fadeIn = lastHideWasForFullscreen
            lastHideWasForFullscreen = false
            let fadingPanels = [dockGlassBackgroundPanel, dockPanel].compactMap { $0 }
            if fadeIn { for panel in fadingPanels { panel.alphaValue = 0 } }
            orderDockSurfaceFront()
            pinResidentPanelsIfNeeded()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for panel in fadingPanels { panel.animator().alphaValue = 1 }
                }
            }
            repairAllSpacesMembershipIfNeeded()
        } else {
            lastHideWasForFullscreen = visibilityState.hideReasons.contains(.fullscreen)
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            orderDockSurfaceOut()
            for panel in [dockGlassBackgroundPanel, dockPanel] { panel?.alphaValue = 1 }
        }
    }

    func noteVisibilityChange(visible: Bool, source: String) {
        DiagnosticVisibilityRecorder.shared.history.noteVisibilityChange(
            unit: stripSurfaceID,
            screen: currentScreen.flatMap { DisplayIdentity.uuidString(for: $0) } ?? fixedUnitDisplayUUID ?? "?",
            previousVisible: panelsAreVisible, visible: visible,
            reasons: visibilityState.hideReasons, source: source
        )
        panelsAreVisible = visible
    }

}
