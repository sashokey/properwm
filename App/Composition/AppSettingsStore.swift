import Combine
import Foundation

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var launchAtLogin: Bool
    private let defaults: UserDefaults
    private static let launchAtLoginKey = "properwm.launchAtLogin"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: Self.launchAtLoginKey)
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard launchAtLogin != value else { return }
        launchAtLogin = value
        defaults.set(value, forKey: Self.launchAtLoginKey)
    }
}
