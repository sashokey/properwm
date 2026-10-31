import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var menu = TaskbarNativeMenuFactory.statusMenu(launchAtLogin: launchAtLoginItem) {
        NSApp.terminate(nil)
    }
    private let settingsCoordinator: SettingsCoordinator
    private let onMenuVisibilityChanged: (Bool) -> Void
    private let launchAtLoginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    init(
        settingsCoordinator: SettingsCoordinator,
        onMenuVisibilityChanged: @escaping (Bool) -> Void
    ) {
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

        settingsCoordinator.$launchAtLoginState
            .sink { [weak self] state in self?.updateLaunchAtLogin(state) }
            .store(in: &subscriptions)
        refreshSystemState()
    }

    func popUpFromTaskbar(with event: NSEvent, in view: NSView) {
        let local = view.convert(event.locationInWindow, from: nil)
        let anchor = NSPoint(x: local.x, y: view.bounds.maxY + menu.size.height)
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuVisibilityChanged(true)
        refreshSystemState()
    }

    func menuDidClose(_ menu: NSMenu) {
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
        let enabled = LaunchAtLoginMenuModel.requestedEnabledValue(
            afterSelecting: settingsCoordinator.launchAtLoginState
        )
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
