import AppKit

extension PanelCoordinator {
    func setupDockPanel() -> Bool {
        guard let screen = resolvedPinnedScreen() ?? mainScreenProvider() ?? screenProvider().first else { return false }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        let panel = NonConstrainingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        panel.isReleasedWhenClosed = false
        let view = TaskbarView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        dockContentHost = ManualPanelHost(contentView: view, in: panel)
        taskbarView = view
        dockPanel = panel
        taskbarPresenter = TaskbarPresenter(
            view: view, runtime: runtime, ordering: stripOrderStore,
            topology: displayTopologyStore, displayUUID: fixedUnitDisplayUUID,
            backgroundMenu: { [weak self] event, source in self?.onRequestTaskbarMenu?(event, source) },
            popupPresented: { [weak self] popup in
                guard let self else { return }
                self.onAccessoryWillOpen?(self, .popup)
                _ = self.overlaySpaceHost?.pin(windowNumbers: [popup.windowNumber])
            },
            contextMenuVisibilityChanged: { [weak self] visible in
                guard let self else { return }
                if visible { self.onAccessoryWillOpen?(self, .popup) }
                self.setTaskbarMenuOpen(visible)
            }
        )
        return true
    }

    func orderDockSurfaceFront() {
        dockPanel?.orderFrontRegardless()
    }

    func orderDockSurfaceOut() {
        taskbarView?.taskbarContent.prepareForHiding()
        dockPanel?.orderOut(nil)
    }

    func presentInitialPanels() {
        guard let dock = dockPanel else { return }
        dock.layoutIfNeeded()
        relayout(animated: false)
        orderDockSurfaceFront()
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
