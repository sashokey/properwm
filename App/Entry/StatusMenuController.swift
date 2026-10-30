import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let store: AppSettingsStore
    private let settingsCoordinator: SettingsCoordinator
    private let onMenuVisibilityChanged: (Bool) -> Void
    private let launchAtLoginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let taskbarSizeView = TaskbarSizeMenuItemView(accessibilityTitle: String(localized: "Taskbar Size"))
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    init(
        store: AppSettingsStore,
        settingsCoordinator: SettingsCoordinator,
        onMenuVisibilityChanged: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.settingsCoordinator = settingsCoordinator
        self.onMenuVisibilityChanged = onMenuVisibilityChanged
        super.init()

        let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "ProperWM")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let sizeItem = NSMenuItem(title: String(localized: "Taskbar Size"), action: nil, keyEquivalent: "")
        sizeItem.view = taskbarSizeView
        menu.addItem(sizeItem)

        taskbarSizeView.onEditingChanged = { [weak settingsCoordinator] editing in
            settingsCoordinator?.setTaskbarHeightEditing(editing)
        }
        taskbarSizeView.onHeightChange = { [weak settingsCoordinator] height in
            settingsCoordinator?.setTaskbarHeight(height)
        }

        settingsCoordinator.$launchAtLoginState
            .sink { [weak self] state in self?.updateLaunchAtLogin(state) }
            .store(in: &subscriptions)
        store.$dockPanelHeight
            .sink { [weak self] height in self?.taskbarSizeView.sync(height: height) }
            .store(in: &subscriptions)
        refreshSystemState()
    }

    func popUpFromTaskbar(with event: NSEvent, in view: NSView) {
        taskbarSizeView.sync(height: store.dockPanelHeight)
        let local = view.convert(event.locationInWindow, from: nil)
        let anchor = NSPoint(x: local.x, y: view.bounds.maxY + menu.size.height)
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuVisibilityChanged(true)
        taskbarSizeView.sync(height: store.dockPanelHeight)
        refreshSystemState()
    }

    func menuDidClose(_ menu: NSMenu) {
        settingsCoordinator.setTaskbarHeightEditing(false)
        onMenuVisibilityChanged(false)
        refreshSystemState()
    }

    private func updateLaunchAtLogin(_ state: LaunchAtLoginState) {
        let presentation = LaunchAtLoginMenuPresentation(state: state)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.isEnabled = presentation.isEnabled
        launchAtLoginItem.state = presentation.isChecked ? .on : .off
    }

    private func refreshSystemState() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await settingsCoordinator.refreshLaunchAtLoginState()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if settingsCoordinator.launchAtLoginState == .requiresApproval {
            settingsCoordinator.openLoginItemsSettings()
            return
        }
        guard let enabled = LaunchAtLoginMenuModel.requestedEnabledValue(
            afterSelecting: settingsCoordinator.launchAtLoginState
        ) else { return }
        if case let .failure(error) = settingsCoordinator.setLaunchAtLogin(enabled) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t Change Open at Login")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
