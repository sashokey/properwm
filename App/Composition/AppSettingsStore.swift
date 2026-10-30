import Combine
import Foundation

enum HoverStyle: String, CaseIterable {
    case standard
    case quiet

    static let `default` = HoverStyle.quiet

    var isExpressive: Bool { self == .standard }

    func showsExpressiveHover(isHovering: Bool) -> Bool { isExpressive && isHovering }

    func showsQuietHoverFeedback(isHovering: Bool) -> Bool {
        !isExpressive && isHovering
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    static let neverHideDelay: Double = -1
    static let neverWakeDelay: Double = 999

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var dockPanelHeight: DockPanelHeight

    let hoverStyle = HoverStyle.standard
    let windowLiftEnabled = true
    let fullscreenIntentEnabled = true
    let taskbarScreenPlacement = TaskbarScreenPlacement.allScreensPerDisplay
    let edgeAutoHideEnabled = false
    let edgeAutoHideDelay = AppSettingsStore.neverHideDelay

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
