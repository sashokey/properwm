import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
    @Published private(set) var launchAtLoginState: LaunchAtLoginState

    private let store: AppSettingsStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private var launchRefreshGeneration: UInt64 = 0


    init(store: AppSettingsStore, launchAtLoginService: LaunchAtLoginServicing) {
        self.store = store
        self.launchAtLoginService = launchAtLoginService
        launchAtLoginState = store.launchAtLogin ? .on : .off
    }

    @discardableResult
    func refreshLaunchAtLoginState() async -> Bool {
        launchRefreshGeneration &+= 1
        let generation = launchRefreshGeneration
        let next = await launchAtLoginService.currentState()
        guard !Task.isCancelled, generation == launchRefreshGeneration else { return false }
        if launchAtLoginState != next { launchAtLoginState = next }
        return true
    }

    func setLaunchAtLogin(_ enabled: Bool) -> Result<Void, Error> {
        launchRefreshGeneration &+= 1
        do {
            try launchAtLoginService.setEnabled(enabled)
            store.setLaunchAtLogin(enabled)
            launchAtLoginState = enabled ? .on : .off
            refreshLaunchAtLoginStateSoon()
            return .success(())
        } catch {
            refreshLaunchAtLoginStateSoon()
            return .failure(error)
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    private func refreshLaunchAtLoginStateSoon() {
        Task { @MainActor [weak self] in
            _ = await self?.refreshLaunchAtLoginState()
        }
    }
}
