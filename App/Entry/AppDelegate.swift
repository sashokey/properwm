import AppKit
import Combine
import QuartzCore
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var localizedDisplayName: String {
        (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? "Tungsten Edge"
    }

    private let installLineage = InstallLineage.capture()
    private let inventoryLog = WindowInventoryAnomalyLog()
    let displayTopologyStore = DisplayTopologyStore(initialSnapshot: DisplayIdentity.topologySnapshot())
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table },
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false }
    )
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    let badgeStore = BadgeStore()
    let keptAppStore = KeptAppStore()
    lazy var stripOrderStore = StripOrderStore(inventoryLog: inventoryLog)
    let drawerOrderStore = DrawerOrderStore()
    let settingsStore = AppSettingsStore()
    let pinnedFolderStore = PinnedFolderStore()
    let shelfStore = ShelfStore()
    let runningApplicationStore = RunningApplicationStore()
    private(set) lazy var appMembershipController = AppMembershipController(
        keptAppStore: keptAppStore,
        drawerStore: drawerStore,
        messagingStore: messagingStore
    )
    private(set) lazy var folderCoverStore = PinnedFolderCoverStore(
        sortOrderProvider: { [pinnedFolderStore] path in pinnedFolderStore.sortOrder(for: path) },
        isUnopenedSeed: { [pinnedFolderStore] path in pinnedFolderStore.isUnopenedSeed(path) }
    )
    private var panelCoordinator: TaskbarScreenOrchestrator?
    private var windowLiftAvoidanceController: WindowLiftAvoidanceController?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        store: settingsStore,
        launchAtLoginService: launchAtLoginService
    )
    private var terminationTask: Task<Void, Never>?
    private var mainLoopStallProbe: Timer?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var badgeContextSubscription: AnyCancellable?
    private let permissionService = PermissionService()
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: Timer?
    private var permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.permission-probe", qos: .utility)
    private var cachedAccessibilityTrusted = false
    private var hasStartedApp = false
    private let permissionLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "permissions")
    private lazy var statusMenuController = StatusMenuController(
        store: settingsStore,
        settingsCoordinator: settingsCoordinator,
        onMenuVisibilityChanged: { [weak self] isOpen in
            self?.panelCoordinator?.setTaskbarMenuOpen(isOpen)
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)

        startMainLoopStallProbeIfTracing()
        StackPopupSnapshotProbe.runIfRequested()

        let isFreshInstall = installLineage == .pristine
        if isFreshInstall {


            pinnedFolderStore.seedDownloadsForFreshInstall(lineage: installLineage)
            keptAppStore.seedSystemAppLauncherForFreshInstall(lineage: installLineage) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
        }

        NSApp.appearance = nil

        let location = AppInstallLocation(
            bundleURL: Bundle.main.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        let trusted = permissionService.hasRequiredPermissions()
        cachedAccessibilityTrusted = trusted
        logPermissionLaunch(installLocation: location, isTrusted: trusted)

        if !location.isTransient {
            terminateOtherInstances()

            _ = statusMenuController

        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionCoordinator?.applicationDidBecomeActive()
        if !installLocation.isTransient {
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }

    private func logPermissionLaunch(installLocation: AppInstallLocation, isTrusted: Bool) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        permissionLogger.info("""
            permission launch version=\(version, privacy: .public) \
            build=\(build, privacy: .public) \
            location=\(installLocation.rawValue, privacy: .public) \
            trusted=\(isTrusted, privacy: .public) \
            bundlePath=\(Bundle.main.bundleURL.path, privacy: .private(mask: .hash))
            """)
    }

    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
        guard !others.isEmpty else { return }

        let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "instance")
        for app in others {
            logger.warning("""
                发现另一个钨极实例，终止它：pid=\(app.processIdentifier, privacy: .public) \
                path=\(app.bundleURL?.path ?? "(unknown)", privacy: .public)
                """)
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in others where !app.isTerminated {
                logger.error("旧实例 pid=\(app.processIdentifier, privacy: .public) 3 秒内未退出，强制结束")
                app.forceTerminate()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {

        permissionCoordinator?.terminationRequested()

        guard let controller = windowLiftAvoidanceController else { return .terminateNow }
        guard permissionService.hasRequiredPermissions() else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self] in
            await controller.stopAndRestore()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemResizeCursor.shared.reset()   // never leave the ▲▼ or a hidden pointer behind us
        SystemCursorHider.shared.show()
        TrashStateStore.shared.stop()

        DocumentUsageStore.shared.stop()
        permissionCoordinator?.terminationRequested()
        windowLiftAvoidanceController?.stop()
        panelCoordinator?.overlaySpaceHost?.tearDown()
        runtime.stop()
    }

    private func showPermissionWindow() {
        guard let coordinator = permissionCoordinator else { return }
        if let permissionWindow {
            resizePermissionWindowToFit()
            permissionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: PermissionOnboardingWindowContent(coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PermissionOnboardingView.contentWidth, height: 260),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.localizedDisplayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        permissionWindow = window
        permissionHostingView = hosting
        resizePermissionWindowToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizePermissionWindowToFit() {
        guard let window = permissionWindow, let coordinator = permissionCoordinator else { return }

        let probe = NSHostingView(rootView: PermissionOnboardingView(coordinator: coordinator))
        probe.setFrameSize(NSSize(width: PermissionOnboardingView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let natural = probe.fittingSize.height

        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = max(200, min(natural, available - 80))
        let size = NSSize(width: PermissionOnboardingView.contentWidth, height: height)
        guard window.contentView?.frame.size != size else { return }

        let before = window.frame
        window.setContentSize(size)
        let after = window.frame
        window.setFrameOrigin(NSPoint(
            x: before.midX - after.width / 2,
            y: before.midY - after.height / 2
        ))
    }

    private func closePermissionWindow() {
        permissionWindow?.orderOut(nil)
        permissionWindow?.close()
        permissionWindow = nil
        permissionHostingView = nil
    }

    private func startTaskbarRuntime() {
        appMembershipController.reconcileInvalidMemberships()
        runningApplicationStore.start()
        runtime.start()

        messagingAutoRegisterSubscription = runningApplicationStore.$runningBundleIDs
            .combineLatest(runtime.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, snapshot in
                guard let self else { return }
                let identifiable = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
                    windows: StripItem.items(from: snapshot).map {
                        .init(bundleID: $0.bundleIdentifier ?? "",
                              title: $0.title,
                              isAppLevelFallback: $0.isAppLevelFallback)
                    },
                    titleMatchesAppName: { title, bundleID in
                        AppDisplayNameResolver.titleMatchesAppName(title, bundleID: bundleID)
                    }
                )
                self.appMembershipController.autoRegisterMessaging(
                    runningBundleIDs: running,
                    mainWindowIdentifiableBundleIDs: identifiable
                )
            }

        badgeContextSubscription = Publishers.CombineLatest3(
            messagingStore.$bundleIDs,
            drawerStore.$bundleIDs,
            runningApplicationStore.$runningBundleIDs
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, drawer, running in
            guard let self else { return }
            self.badgeStore.updateMessagingContext(
                visibleMessagingIDs: AppMembershipProjection.badgeEligibleIDs(
                    isMessagingApp: { self.messagingStore.isMessagingApp($0) },
                    drawerIDs: drawer,
                    runningIDs: running
                ),
                runningBundleIDs: running
            )
        }

        let coordinator = TaskbarScreenOrchestrator(
            runtime: runtime,
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            badgeStore: badgeStore,
            stripOrderStore: stripOrderStore,
            drawerOrderStore: drawerOrderStore,
            settingsStore: settingsStore,
            pinnedFolderStore: pinnedFolderStore,
            folderCoverStore: folderCoverStore,
            shelfStore: shelfStore,
            keptAppStore: keptAppStore,
            runningApplicationStore: runningApplicationStore,
            appMembershipController: appMembershipController,
            displayTopologyStore: displayTopologyStore
        )
        panelCoordinator = coordinator
        runtime.onToggleDrawer = { [weak coordinator] in coordinator?.toggleDrawer() }
        settingsCoordinator.taskbarHeightSessionHandler = { [weak coordinator] editing in
            coordinator?.setSettingsHeightSessionActive(editing)
        }
        settingsCoordinator.taskbarHeightUpdateHandler = { [weak coordinator] in
            coordinator?.commitSettingsPanelHeight()
        }
        coordinator.onAddFolder = { [weak self] in self?.presentAddPinnedFolderPanel() }
        coordinator.onRequestTaskbarMenu = { [weak self] event, view in
            self?.statusMenuController.popUpFromTaskbar(with: event, in: view)
        }
        coordinator.start()
        let windowLiftAvoidanceController = WindowLiftAvoidanceController(host: coordinator)
        self.windowLiftAvoidanceController = windowLiftAvoidanceController
        windowLiftAvoidanceController.setEnabledBySetting(settingsStore.windowLiftEnabled)
        windowLiftAvoidanceController.start()
        DocumentUsageStore.shared.start()
        TrashStateStore.shared.setEnabled(settingsStore.showTrash)
        TrashStateStore.shared.start(revealOpenedWindow: TrashStateStore.revealTrashWindow(runtime: runtime))
        badgeStore.start()
    }

    func presentAddPinnedFolderPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        panel.message = String(localized: "Choose a folder to pin to the taskbar")
        if panel.runModal() == .OK {
            for url in panel.urls { pinnedFolderStore.add(url.path) }
        }
    }

    private func startMainLoopStallProbeIfTracing() {
        guard HoverTrace.isEnabled else { return }
        let clock = StallProbeClock(expected: CACurrentMediaTime() + 0.008)
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            let now = CACurrentMediaTime()
            HoverTrace.mainLoopStall(lateMs: (now - clock.expected) * 1000)
            clock.expected = now + 0.008
        }
        RunLoop.main.add(timer, forMode: .common)
        mainLoopStallProbe = timer
    }

}

extension AppDelegate: PermissionEffectHandler {
    func startApp() {
        guard !hasStartedApp else { return }
        hasStartedApp = true
        startTaskbarRuntime()
    }

    func setActivationPolicy(_ policy: PermissionActivationPolicy) {
        switch policy {
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        case .regular:
            NSApp.setActivationPolicy(.regular)
        }
    }

    func showGuideWindow() { showPermissionWindow() }
    func updateGuideWindow() { resizePermissionWindowToFit() }
    func closeGuideWindow() { closePermissionWindow() }

    func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func terminateSelf() { NSApp.terminate(nil) }

    func startWatchdog() {
        stopWatchdog()
        permissionWatchdogGate.start()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePermissionProbe()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionWatchdogTimer = timer
    }

    func stopWatchdog() {
        permissionWatchdogTimer?.invalidate()
        permissionWatchdogTimer = nil
        permissionWatchdogGate.stop()
    }

    private func schedulePermissionProbe() {
        guard let generation = permissionWatchdogGate.beginProbe() else { return }
        let permissionService = permissionService
        permissionProbeQueue.async { [weak self] in
            let trusted = permissionService.hasRequiredPermissions()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.permissionWatchdogGate.completeProbe(generation: generation) else { return }
                self.cachedAccessibilityTrusted = trusted
                self.permissionCoordinator?.sampleTrust(trusted)
            }
        }
    }

    func freezeLiftSnapshots() {
        windowLiftAvoidanceController?.beginPermissionUncertainty()
    }

    func unfreezeLiftSnapshots() {
        windowLiftAvoidanceController?.endPermissionUncertainty()
    }

    func suspendPanelsAndStores() {
        TrashStateStore.shared.stop()
        messagingAutoRegisterSubscription?.cancel()
        messagingAutoRegisterSubscription = nil
        badgeContextSubscription?.cancel()
        badgeContextSubscription = nil
        runtime.onToggleDrawer = nil

        DocumentUsageStore.shared.stop()
        panelCoordinator?.suspendAndRelease()
        panelCoordinator = nil
        badgeStore.stop()
        runtime.stop()
        runningApplicationStore.stop()
    }

    func restoreLiftedWindows(episode: UInt64) async {
        await windowLiftAvoidanceController?.restoreAndStopForPermissionRecovery()
        windowLiftAvoidanceController = nil
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let url = Bundle.main.bundleURL

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }
}

private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}
