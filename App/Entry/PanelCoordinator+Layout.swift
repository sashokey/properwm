import AppKit
import Combine

extension PanelCoordinator {
    func subscribeSettings() {
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout(animated: false) }
    }

    func relayout(animated: Bool) {
        guard let panel = dockPanel else { return }
        let screen = resolvedPinnedScreen() ?? panelCurrentScreen(panel: panel)
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        if let transaction = fullscreenIntentTransaction, transaction.screenCGFrame != Self.toCGRect(screen) {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        if panel.frame != frame {
            taskbarView?.taskbarContent.prepareForHiding()
            panel.setFrame(frame, display: true)
        }
        dockContentHost?.layoutContent()
        onPanelScreenChanged?()
    }

    func screenParametersChanged() {
        taskbarView?.taskbarContent.prepareForHiding()
        relayout(animated: false)
        cancelFullscreenIntentIfContextChanged()
        reconcilePanelVisibility()
    }
}
