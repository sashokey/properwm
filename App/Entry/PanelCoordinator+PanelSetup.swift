import AppKit

extension PanelCoordinator {
    func setupDockPanel(makeTaskbarView: (CGRect) -> TaskbarView = { TaskbarView(frame: $0) }) -> Bool {
        guard let screen = resolvedPinnedScreen() ?? mainScreenProvider() ?? screenProvider().first else { return false }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        let panel = NonConstrainingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        panel.isReleasedWhenClosed = false
        let view = makeTaskbarView(CGRect(origin: .zero, size: frame.size))
        view.taskbarContent.admitWindowList = { [weak self] focusForKeyboard in
            guard let self else { return false }
            return self.onAccessoryWillOpen?(self, focusForKeyboard ? .explicit : .implicit) ?? true
        }
        view.autoresizingMask = [.width, .height]
        dockContentHost = ManualPanelHost(contentView: view, in: panel)
        taskbarView = view
        dockPanel = panel
        taskbarPresenter = TaskbarPresenter(
            view: view, runtime: runtime, ordering: stripOrderStore,
            topology: displayTopologyStore, spaces: spaceStore, displayUUID: fixedUnitDisplayUUID,
            backgroundMenu: { [weak self] event, source in self?.onRequestTaskbarMenu?(event, source) },
            popupPresented: { [weak self] popup in
                self?.overlaySpaceHost?.pin(panels: [popup])
            },
            contextMenuVisibilityChanged: { [weak self] visible in
                guard let self, visible else { return }
                _ = self.onAccessoryWillOpen?(self, .explicit)
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
        relayout()
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
