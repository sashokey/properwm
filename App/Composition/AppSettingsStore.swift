import Combine
import Foundation

@MainActor
final class AppSettingsStore: ObservableObject {

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var dockPanelHeight: DockPanelHeight

    let windowLiftEnabled = true
    let fullscreenIntentEnabled = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        if let value = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.dockPanelHeight)) {
            dockPanelHeight = DockPanelHeight(clamping: CGFloat(value))
        } else {
            dockPanelHeight = .default
        }
        defaults.set(Double(dockPanelHeight.points), forKey: Keys.dockPanelHeight)
    }

    func setDockPanelHeight(_ value: DockPanelHeight) {
        guard dockPanelHeight != value else { return }
        dockPanelHeight = value
        defaults.set(Double(value.points), forKey: Keys.dockPanelHeight)
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard launchAtLogin != value else { return }
        launchAtLogin = value
        defaults.set(value, forKey: Keys.launchAtLogin)
    }
}

private enum Keys {
    static let launchAtLogin = "properwm.launchAtLogin"
    static let dockPanelHeight = "properwm.taskbarHeight"
}
