import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

extension PanelCoordinator {
    func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedDisplayUUID else { return nil }
        let screens = screenProvider()
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: pinnedUUID,
            screenUUIDs: screens.map { DisplayIdentity.uuidString(for: $0) },
            mainIndex: mainScreenProvider().flatMap { screens.firstIndex(of: $0) }
        )
        switch outcome {
        case .matched(let index), .fallback(let index):
            return screens[index]
        case nil:
            return nil
        }
    }

    func reconcilePanelVisibility() {
        applyPanelVisibility()
    }

    func applyPanelVisibility() {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible && currentScreen != nil
        guard shouldShow != panelsAreVisible else { return }
        panelsAreVisible = shouldShow
        if shouldShow {
            let fadeIn = lastHideWasForFullscreen
            lastHideWasForFullscreen = false
            let fadingPanels = [dockPanel].compactMap { $0 }
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
            taskbarView?.taskbarContent.prepareForHiding()
            orderDockSurfaceOut()
            for panel in [dockPanel] { panel?.alphaValue = 1 }
        }
    }

}
