import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable, Sendable {
    case off
    case on
    case requiresApproval
}

struct LaunchAtLoginMenuPresentation: Equatable {
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    var showsSettingsItem: Bool

    init(title: String, isEnabled: Bool, isChecked: Bool, showsSettingsItem: Bool) {
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.showsSettingsItem = showsSettingsItem
    }

    init(state: LaunchAtLoginState) {
        isEnabled = true
        switch state {
        case .off:
            title = String(localized: "Open at Login")
            isChecked = false
            showsSettingsItem = false
        case .on:
            title = String(localized: "Open at Login")
            isChecked = true
            showsSettingsItem = false
        case .requiresApproval:
            title = String(localized: "Open at Login (Pending Approval)")
            isChecked = false
            showsSettingsItem = true
        }
    }
}

enum LaunchAtLoginMenuModel {
    static func requestedEnabledValue(afterSelecting state: LaunchAtLoginState) -> Bool {
        state != .on
    }
}

@MainActor
protocol LaunchAtLoginServicing {
    func currentState() async -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

protocol LaunchAtLoginBackend: Sendable {
    func readState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private let backend: any LaunchAtLoginBackend
    private let readerQueue = DispatchQueue(label: "io.github.sashokey.properwm.launch-at-login-reader", qos: .userInitiated)

    init(backend: any LaunchAtLoginBackend = ModernLoginItemBackend()) {
        self.backend = backend
    }

    func currentState() async -> LaunchAtLoginState {
        let backend = backend
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: backend.readState())
            }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try backend.setEnabled(enabled)
    }

    func openSystemSettings() {
        backend.openSettings()
    }
}

struct ModernLoginItemBackend: LaunchAtLoginBackend {
    func readState() -> LaunchAtLoginState {
        Self.mapStatus(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .off
        @unknown default:
            return .off
        }
    }
}
