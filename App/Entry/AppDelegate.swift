import AppKit
import Combine
import QuartzCore
import SwiftUI
#if DEBUG
import os
#endif

@MainActor
struct ApplicationEnvironment {
    var bundleURL = Bundle.main.bundleURL
    var permissionService = PermissionService()
    var permissionProbe: @Sendable () -> Bool = { PermissionService().hasRequiredPermissions() }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var retirePreviousInstances: @MainActor @Sendable () -> (@MainActor @Sendable () async -> Bool)? = {
        AppDelegate.retirePreviousInstances()
    }
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
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table }
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
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    #if DEBUG
    private var mainLoopStallProbe: Timer?
    #endif
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var permissionService: PermissionService { environment.permissionService }
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: Timer?
    private var permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "io.github.sashokey.properwm.permission-probe", qos: .utility)
    #if DEBUG
    private var cachedAccessibilityTrusted = false
    #endif
    private var hasStartedApp = false
    #if DEBUG
    private let permissionLogger = Logger(subsystem: "io.github.sashokey.properwm", category: "permissions")
    #endif
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

        #if DEBUG
        startMainLoopStallProbeIfTracing()
        #endif

        environment.resetAppearance()

        let location = AppInstallLocation(
            bundleURL: environment.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        guard !location.isTransient, let waitForExit = environment.retirePreviousInstances() else {
            finishLaunching(at: location)
            return
        }
        startupTask = Task { @MainActor [weak self] in
            let ready = await waitForExit()
            guard !Task.isCancelled, let self else { return }
            self.startupTask = nil
            if ready {
                self.finishLaunching(at: location)
            } else {
                self.environment.terminate()
            }
        }
    }

    private func finishLaunching(at location: AppInstallLocation) {
        let trusted = permissionService.hasRequiredPermissions()
        #if DEBUG
        cachedAccessibilityTrusted = trusted
        logPermissionLaunch(installLocation: location, isTrusted: trusted)
        #endif

        if !location.isTransient { _ = statusMenuController }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location, now: environment.now
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard permissionCoordinator != nil else { return false }
        guard !installLocation.isTransient else { return true }
        statusMenuController.showStatusBarIcon()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let permissionCoordinator else { return }
        permissionCoordinator.applicationDidBecomeActive()
        if !installLocation.isTransient {
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }

    #if DEBUG
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
    #endif

    fileprivate static func retirePreviousInstances() -> (@MainActor @Sendable () async -> Bool)? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let origin = ApplicationOrigin(bundleURL: Bundle.main.bundleURL) else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated
                && ApplicationOrigin(bundleURL: $0.bundleURL) == origin }
        guard !others.isEmpty else { return nil }
        guard let myStart = ProcessLiveness.startTime(pid: myPID) else { return { false } }

        let myRank = (myStart.tv_sec, myStart.tv_usec, myPID)
        var earlier: [(NSRunningApplication, ProcessGeneration)] = []
        for app in others {
            let pid = app.processIdentifier
            guard let start = ProcessLiveness.startTime(pid: pid) else {
                if ProcessLiveness.isAlive(pid: pid) { return { false } }
                continue
            }
            if (start.tv_sec, start.tv_usec, pid) < myRank {
                earlier.append((app, ProcessGeneration(start)))
            }
        }
        guard !earlier.isEmpty else { return nil }

        let predecessors = earlier
        return {
            guard !Task.isCancelled else { return false }
            let deadline = ContinuousClock.now + .seconds(10)
            for (app, expected) in predecessors {
                guard !app.isTerminated,
                      ProcessLiveness.startTime(pid: app.processIdentifier).map(ProcessGeneration.init) == expected,
                      ApplicationOrigin(bundleURL: app.bundleURL) == origin else { continue }
                _ = app.terminate()
            }

            while predecessors.contains(where: { app, expected in
                guard !app.isTerminated else { return false }
                let pid = app.processIdentifier
                guard let current = ProcessLiveness.startTime(pid: pid) else {
                    return ProcessLiveness.isAlive(pid: pid)
                }
                return ProcessGeneration(current) == expected
            }) {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return !Task.isCancelled
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupTask?.cancel()
        startupTask = nil
        permissionCoordinator?.terminationRequested()
        if hasStartedApp { runtime.stop() }

        guard let controller = windowLiftAvoidanceController else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        let reply = environment.replyToTermination
        terminationTask = Task { @MainActor [weak self] in
            let result = await controller.stopAndRestore()
            #if DEBUG
            if case let .incomplete(remaining) = result {
                Logger(subsystem: "io.github.sashokey.properwm", category: "WindowRestoration")
                    .error("termination restoration incomplete count=\(remaining, privacy: .public)")
            }
            #endif
            self?.windowLiftAvoidanceController = nil
            self?.terminationTask = nil
            reply(sender, true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        permissionCoordinator?.terminationRequested()
        windowLiftAvoidanceController?.stop()
        panelCoordinator?.overlaySpaceHost?.tearDown()
        if hasStartedApp { runtime.stop() }
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

    #if DEBUG
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
    #endif

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
                #if DEBUG
                if self.cachedAccessibilityTrusted != trusted {
                    self.permissionLogger.notice("permission-trust-changed trusted=\(trusted, privacy: .public)")
                }
                self.cachedAccessibilityTrusted = trusted
                #endif
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

    func restoreLiftedWindows(episode: UInt64) async -> WindowRestorationCompletion {
        guard let controller = windowLiftAvoidanceController else { return .complete }
        let result = await controller.restoreAndStopForPermissionRecovery()
        if result == .complete { windowLiftAvoidanceController = nil }
        #if DEBUG
        if case let .incomplete(remaining) = result {
            permissionLogger.error("permission recovery restoration incomplete count=\(remaining, privacy: .public)")
        }
        #endif
        return result
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        await environment.launchInstance(environment.bundleURL)
    }
}

#if DEBUG
private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}
#endif
