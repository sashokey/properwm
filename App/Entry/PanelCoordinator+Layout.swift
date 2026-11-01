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
        guard let screen = resolvedPinnedScreen() ?? panelCurrentScreen(panel: panel) else {
            orderDockSurfaceOut()
            return
        }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        if panel.frame != frame {
            taskbarView?.taskbarContent.prepareForHiding()
            panel.setFrame(frame, display: true)
        }
        dockContentHost?.layoutContent()
    }

    func screenParametersChanged() {
        taskbarView?.taskbarContent.prepareForHiding()
        relayout(animated: false)
        reconcilePanelVisibility()
    }
}
