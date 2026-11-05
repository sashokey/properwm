import AppKit
import Combine
import QuartzCore
import SwiftUI
import os

@MainActor
struct ApplicationEnvironment {
    var bundleURL = Bundle.main.bundleURL
    var permissionService = PermissionService()
    var permissionProbe: @Sendable () -> Bool = { PermissionService().hasRequiredPermissions() }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var removeOtherInstances: @MainActor @Sendable () -> Void = { AppDelegate.terminateOtherInstances() }
    var resetAppearance: @MainActor @Sendable () -> Void = { NSApp.appearance = nil }
    var setActivationPolicy: @MainActor @Sendable (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }
    var activateApplication: @MainActor @Sendable () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var terminate: @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }
    var replyToTermination: @MainActor @Sendable (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    var makeStatusItem: @MainActor @Sendable () -> any StatusItemPresenting = { NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
    var makePermissionWindow: @MainActor @Sendable (NSRect, NSWindow.StyleMask) -> NSWindow = {
        NSWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: false)
    }
    var makePanels: @MainActor @Sendable (AppRuntime, StripOrderStore, DisplayTopologyStore) -> TaskbarScreenOrchestrator = {
        TaskbarScreenOrchestrator(runtime: $0, stripOrderStore: $1, displayTopologyStore: $2)
    }
    var makeLift: @MainActor @Sendable (WindowLiftAvoidanceHost) -> WindowLiftAvoidanceController = { WindowLiftAvoidanceController(host: $0) }
    var launchInstance: @MainActor @Sendable (URL) async -> Result<Void, Error> = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(returning: .failure(error)) }
                else { continuation.resume(returning: .success(())) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var localizedDisplayName: String {
        (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? "ProperWM"
    }

    private let inventoryLog = WindowInventoryAnomalyLog()
    private let environment: ApplicationEnvironment
    let displayTopologyStore: DisplayTopologyStore
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table },
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false }
    )
    lazy var stripOrderStore = StripOrderStore(inventoryLog: inventoryLog)
    let settingsStore: AppSettingsStore
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
    private var permissionService: PermissionService { environment.permissionService }
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: Timer?
    private var permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "io.github.sashokey.properwm.permission-probe", qos: .utility)
    private var cachedAccessibilityTrusted = false
    private var hasStartedApp = false
    private let permissionLogger = Logger(subsystem: "io.github.sashokey.properwm", category: "permissions")
    private lazy var statusMenuController = StatusMenuController(
        settingsCoordinator: settingsCoordinator,
        statusItem: environment.makeStatusItem(), quit: environment.terminate
    )

    override convenience init() { self.init(environment: ApplicationEnvironment()) }

    init(environment: ApplicationEnvironment, runtime: AppRuntime? = nil,
         displayTopologyStore: DisplayTopologyStore? = nil, settingsStore: AppSettingsStore? = nil,
         stripOrderStore: StripOrderStore? = nil) {
        self.environment = environment
        self.displayTopologyStore = displayTopologyStore ?? DisplayTopologyStore(initialSnapshot: DisplayIdentity.topologySnapshot())
        self.settingsStore = settingsStore ?? AppSettingsStore()
        super.init()
        if let runtime { self.runtime = runtime }
        if let stripOrderStore { self.stripOrderStore = stripOrderStore }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)

        startMainLoopStallProbeIfTracing()

        environment.resetAppearance()

        let location = AppInstallLocation(
            bundleURL: environment.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        let trusted = permissionService.hasRequiredPermissions()
        cachedAccessibilityTrusted = trusted
        logPermissionLaunch(installLocation: location, isTrusted: trusted)

        if !location.isTransient {
            environment.removeOtherInstances()

            _ = statusMenuController

        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location, now: environment.now
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !installLocation.isTransient else { return true }
        statusMenuController.showStatusBarIcon()
        return false
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

    fileprivate static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        guard let origin = ApplicationOrigin(bundleURL: Bundle.main.bundleURL) else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated
                && ApplicationOrigin(bundleURL: $0.bundleURL) == origin }
        guard !others.isEmpty else { return }
        let generations = Dictionary(uniqueKeysWithValues: others.compactMap { app in
            ProcessLiveness.startTime(pid: app.processIdentifier).map { (app.processIdentifier, ProcessGeneration($0)) }
        })

        let logger = Logger(subsystem: "io.github.sashokey.properwm", category: "instance")
        for app in others {
            guard let expected = generations[app.processIdentifier],
                  ProcessLiveness.startTime(pid: app.processIdentifier).map(ProcessGeneration.init) == expected,
                  ApplicationOrigin(bundleURL: app.bundleURL) == origin else { continue }
            logger.warning("""
                发现另一个ProperWM实例，终止它：pid=\(app.processIdentifier, privacy: .public) \
                path=\(app.bundleURL?.path ?? "(unknown)", privacy: .public)
                """)
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in others where !app.isTerminated {
                guard let expected = generations[app.processIdentifier],
                      ProcessLiveness.startTime(pid: app.processIdentifier).map(ProcessGeneration.init) == expected,
                      ApplicationOrigin(bundleURL: app.bundleURL) == origin else { continue }
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

        let reply = environment.replyToTermination
        terminationTask = Task { @MainActor [weak self] in
            await controller.stopAndRestore()
            self?.terminationTask = nil
            reply(sender, true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {

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
            environment.activateApplication()
            return
        }

        let hosting = NSHostingView(rootView: PermissionOnboardingWindowContent(coordinator: coordinator))
        let window = environment.makePermissionWindow(
            NSRect(x: 0, y: 0, width: PermissionOnboardingView.contentWidth, height: 260), [.titled, .miniaturizable]
        )
        window.title = Self.localizedDisplayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        permissionWindow = window
        permissionHostingView = hosting
        resizePermissionWindowToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        environment.activateApplication()
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
        runtime.start()
        let coordinator = environment.makePanels(runtime, stripOrderStore, displayTopologyStore)
        panelCoordinator = coordinator
        coordinator.onRequestTaskbarMenu = { [weak self] event, view in
            self?.statusMenuController.popUpFromTaskbar(with: event, in: view)
        }
        coordinator.start()
        let lift = environment.makeLift(coordinator)
        windowLiftAvoidanceController = lift
        lift.start()
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
            environment.setActivationPolicy(.accessory)
        case .regular:
            environment.setActivationPolicy(.regular)
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

    func terminateSelf() { environment.terminate() }

    func startWatchdog() {
        stopWatchdog()
        permissionWatchdogGate.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePermissionProbe()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        permissionWatchdogTimer = timer
    }

    func stopWatchdog() {
        permissionWatchdogTimer?.invalidate()
        permissionWatchdogTimer = nil
        permissionWatchdogGate.stop()
    }

    func schedulePermissionProbe() {
        guard let generation = permissionWatchdogGate.beginProbe() else { return }
        let probe = environment.permissionProbe
        permissionProbeQueue.async { [weak self] in
            let trusted = probe()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.permissionWatchdogGate.completeProbe(generation: generation) else { return }
                if self.cachedAccessibilityTrusted != trusted {
                    self.permissionLogger.notice("permission-trust-changed trusted=\(trusted, privacy: .public)")
                }
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
        panelCoordinator?.suspendAndRelease()
        panelCoordinator = nil
        runtime.stop()
    }

    func restoreLiftedWindows(episode: UInt64) async {
        await windowLiftAvoidanceController?.restoreAndStopForPermissionRecovery()
        windowLiftAvoidanceController = nil
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        await environment.launchInstance(environment.bundleURL)
    }
}

private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}
