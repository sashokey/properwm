import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

private final class LifecycleReader: AppTrackerWindowReading, @unchecked Sendable {
    struct State {
        var count = 0
        var usedMainThread = false
    }
    let state = Mutex(State())
    let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { read(pid) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { read(pid) }

    private func read(_ pid: pid_t) -> AXWindowReadResult {
        let index = state.withLock { state in
            defer { state.count += 1 }
            state.usedMainThread = state.usedMainThread || Thread.isMainThread
            return state.count
        }
        guard gates.indices.contains(index) else { return .unread(.cannotComplete) }
        _ = gates[index].wait(timeout: .now() + 3)
        return .success([AXWindowSnapshot(pid: pid, cgWindowID: 77, titleRead: .value("Read \(index)"),
            bounds: CGRect(x: 40, y: 40, width: 640, height: 480), role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String, isMinimized: false, isFocusedWindow: false,
            element: AXUIElementCreateApplication(pid))])
    }
}

private final class LifecycleProcess: AppTrackerProcessProviding, Sendable {
    let generation = Mutex(Int64(1))
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: generation.withLock { $0 }, startTimeUsec: 0, bundleID: bundleID)
    }
}

@MainActor
final class InventoryLifecycleTests: XCTestCase {
    func testFocusedWindowReadDoesNotEnumerateWindowsOrReadTheirContent() {
        let desktop = BehaviorDesktop()
        let attributes = Mutex<[String]>([])
        desktop.state.withLock {
            $0.focused = 1002
            $0.beforeRead = { name in attributes.withLock { $0.append(name) } }
        }
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: OperationCancellation()).result, .window(1002))
        XCTAssertEqual(attributes.withLock { $0 }, [kAXFocusedWindowAttribute as String])
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        desktop.state.withLock { $0.focused = nil }
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: OperationCancellation()).result, .none)
    }

    func testCancelledFocusedWindowReadCannotPublishAnIdentity() {
        let desktop = BehaviorDesktop()
        let cancellation = OperationCancellation()
        desktop.state.withLock { $0.beforeRead = { _ in cancellation.cancel() } }
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: cancellation).result, .unread(.cannotComplete))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testFocusedWindowReadRejectsAnElementWhoseOwnerChangedDuringCapture() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.focused = 1002
            $0.beforeRead = { [weak desktop] attribute in
                guard attribute == kAXFocusedWindowAttribute as String else { return }
                desktop?.state.withLock { state in
                    guard let old = state.windows[1002] else { return }
                    state.windows[1002] = WindowRecord(id: old.id, appID: old.appID, pid: -42000,
                        bundleIdentifier: old.bundleIdentifier, title: old.title, bounds: old.bounds,
                        status: old.status, cgWindowID: old.cgWindowID)
                }
            }
        }
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertEqual(reader.focusedWindowRead(forPID: -41000, messagingTimeout: 0.05,
                                               cancellation: OperationCancellation()).result, .unread(.invalidUIElement))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    private func focusFixtureApp(_ focused: CGWindowID? = nil, title: String = "Original") -> AppEntry {
        let entries = [UInt32(77), 88].map { id in
            WindowEntry(cgWindowID: id, token: "focus-\(id)", title: title,
                        bounds: CGRect(x: CGFloat(id), y: 30, width: 600, height: 500),
                        isMinimized: false, isFocused: id == focused)
        }
        return AppEntry(pid: 42, bundleIdentifier: "test.focus", appName: "Focus", activationPolicy: .regular,
            executablePath: nil, windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
            windowOrder: [77, 88], isHidden: false)
    }

    private func focusTracker(_ reader: FocusLifecycleReader, process: LifecycleProcess = LifecycleProcess(),
                              focused: CGWindowID? = nil) -> AppTracker {
        let tracker = AppTracker(reader: reader, processProvider: process, onScreenWindowIDsProvider: { [77, 88] })
        tracker.installFixtureForTesting(focusFixtureApp(focused))
        tracker.setFrontmostPIDForTesting(42)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77, 88])
        return tracker
    }

    private func waitForFocus(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testFocusBurstCoalescesWithoutPublishingAnOlderFocusedWindow() async {
        let reader = FocusLifecycleReader()
        let tracker = focusTracker(reader)
        defer { reader.gate.signal(); tracker.stop() }
        var observed: [CGWindowID] = []
        let subscription = tracker.$snapshot.sink { snapshot in
            if let id = snapshot.windows.values.first(where: { $0.status == .active })?.cgWindowID { observed.append(id) }
        }
        defer { subscription.cancel() }
        tracker.handleFocusedWindowChanged(pid: 42)
        await waitForFocus { reader.state.withLock { $0.reads == 1 } }
        reader.state.withLock { $0.result = .window(88) }
        for _ in 0..<20 { tracker.handleFocusedWindowChanged(pid: 42) }
        XCTAssertEqual(reader.state.withLock { $0.reads }, 1)
        reader.gate.signal()
        await waitForFocus { tracker.snapshot.windows[WindowID(rawValue: "cgw-88")]?.status == .active }
        XCTAssertEqual(reader.state.withLock { $0.reads }, 2)
        XCTAssertFalse(observed.contains(77))
        XCTAssertFalse(reader.state.withLock { $0.usedMainThread })
    }

    func testStopAndProcessReplacementRejectLateFocusedWindowReads() async {
        for replace in [false, true] {
            let reader = FocusLifecycleReader()
            let process = LifecycleProcess()
            let tracker = focusTracker(reader, process: process)
            defer { reader.gate.signal(); tracker.stop() }
            tracker.handleFocusedWindowChanged(pid: 42)
            await waitForFocus { reader.state.withLock { $0.reads == 1 } }
            let pending = tracker.pendingInventoryWorkForTesting
            if replace {
                tracker.handleAppTerminated(pid: 42)
                process.generation.withLock { $0 += 1 }
                tracker.installFixtureForTesting(focusFixtureApp(title: "Replacement"))
                tracker.setFrontmostPIDForTesting(42)
                tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77, 88])
            } else { tracker.stop() }
            reader.gate.signal()
            for task in pending { await task.value }
            XCTAssertFalse(tracker.snapshot.windows.values.contains { $0.status == .active })
            if replace { XCTAssertEqual(Set(tracker.snapshot.windows.values.map(\.title)), ["Replacement"]) }
            else { XCTAssertTrue(tracker.snapshot.windows.isEmpty) }
        }
    }

    func testUnavailableFocusPreservesHighlightAndConfirmedNoWindowClearsIt() async {
        let reader = FocusLifecycleReader(blockFirst: false)
        reader.state.withLock { $0.result = .unread(.cannotComplete) }
        let tracker = focusTracker(reader, focused: 77)
        defer { tracker.stop() }
        tracker.handleFocusedWindowChanged(pid: 42)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-77")]?.status, .active)
        reader.state.withLock { $0.result = .none }
        tracker.handleFocusedWindowChanged(pid: 42)
        await waitForFocus { !tracker.snapshot.windows.values.contains { $0.status == .active } }
        XCTAssertEqual(reader.state.withLock { $0.reads }, 2)
    }

    func testAFullReadThatCapturesFocusLaterCanAdvanceTheFocusedWindow() async {
        let desktop = BehaviorDesktop()
        let gate = FocusListGate()
        desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 1002], onScreenWindowIDs: [1001, 1002],
            windowIDsByPID: [-41000: [1001, 1002]], alphaByWindowID: [1001: 1, 1002: 1])
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 1002] })
        let entries = [UInt32(1001), 1002].map { id in
            WindowEntry(cgWindowID: id, token: "tabgrp-\(id)", title: "Window \(id)",
                        bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050), isMinimized: false, isFocused: false,
                        everSeenVisible: true)
        }
        tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.Editor", appName: "Editor",
            activationPolicy: .regular, executablePath: nil,
            windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
            windowOrder: [1001, 1002], isHidden: false))
        tracker.setFrontmostPIDForTesting(-41000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002])
        defer { gate.release.signal(); tracker.stop() }
        tracker.handleFocusedWindowChanged(pid: -41000)
        await waitForFocus { gate.entered.withLock { $0 } && tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status == .active }
        let pending = tracker.pendingInventoryWorkForTesting
        desktop.state.withLock { $0.focused = 1002 }
        gate.release.signal()
        for task in pending { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1002")]?.status, .active)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status, .inactive)
    }

    func testFocusBetweenMonitorsUpdatesButtonsBeforeAnInFlightInventoryReadCompletes() async throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.windows[1001]?.bounds = CGRect(x: 40, y: 30, width: 800, height: 700)
            $0.windows[1002]?.bounds = CGRect(x: 1040, y: 30, width: 800, height: 700)
            $0.windows[2001]?.bounds = CGRect(x: 80, y: 30, width: 800, height: 700)
        }
        let table = WindowDisplayAttribution.Table(displays: [
            .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "right", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        ], primaryUUID: "left")
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001, 1002, 2001], onScreenWindowIDs: [1001, 1002, 2001],
            windowIDsByPID: [-41000: [1001, 1002], -42000: [2001]],
            alphaByWindowID: [1001: 1, 1002: 1, 2001: 1])
        let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001, 1002, 2001] }, displayTableProvider: { table })
        for pid: pid_t in [-41000, -42000] {
            let records = desktop.state.withLock { $0.windows.values.filter { $0.pid == pid }.sorted { $0.cgWindowID! < $1.cgWindowID! } }
            let entries = records.map { record in
                WindowEntry(cgWindowID: record.cgWindowID!, token: record.groupID, title: record.title, bounds: record.bounds,
                            isMinimized: false, isFocused: record.cgWindowID == 1001 || record.cgWindowID == 2001,
                            everSeenVisible: true, displayUUID: record.cgWindowID == 1002 ? "right" : "left")
            }
            tracker.installFixtureForTesting(AppEntry(pid: pid, bundleIdentifier: records[0].bundleIdentifier,
                appName: pid == -41000 ? "Chrome" : "Codex", activationPolicy: .regular, executablePath: nil,
                windowsByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.cgWindowID, $0) }),
                windowOrder: entries.map(\.cgWindowID), isHidden: false, processGeneration: .init(timeval(tv_sec: 1, tv_usec: 0))))
        }
        tracker.setFrontmostPIDForTesting(-41000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002, 2001])
        let runtime = AppRuntime(tracker: ControlledInventoryLifecycle(tracker), isAccessibilityTrusted: { true })
        let spaces = TaskbarSpaceStore(read: { requests in
            .init(layouts: ["left": .init(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1),
                            "right": .init(orderedSpaceIDs: [2], fullscreenSpaceIDs: [], currentSpaceID: 2)],
                  memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([$0.identity.windowID == 1002 ? 2 : 1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "ProperWM.FocusLatency.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 2,
            identifiedDisplayUUIDs: ["left", "right"], attributionTable: table))
        let views = [TaskbarView(frame: CGRect(x: 0, y: 0, width: 1000, height: 32)),
                     TaskbarView(frame: CGRect(x: 0, y: 0, width: 1000, height: 32))]
        let presenters = zip(views, ["left", "right"]).map { view, display in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering, topology: topology, spaces: spaces,
                displayUUID: display, backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        }
        runtime.start()
        spaces.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { spaces.stop(); runtime.stop(); withExtendedLifetime(presenters) {} }
        func active(_ index: Int, _ window: String) -> Bool {
            views[index].taskbarContent.buttonViews["window:" + window]?.isActiveWindow == true
        }
        func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(1)
            while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(predicate(), file: file, line: line)
        }
        await wait { active(0, "tabgrp-editor-a") }
        tracker.setFrontmostPIDForTesting(-42000)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [1001, 1002, 2001])
        await wait { active(0, "tabgrp-browser-c") && !active(0, "tabgrp-editor-a") }
        tracker.setFrontmostPIDForTesting(-41000)
        desktop.state.withLock { $0.focused = 1002 }
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        await wait { active(1, "tabgrp-editor-b") && !active(0, "tabgrp-browser-c") }
        let gate = FocusInventoryGate()
        desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        tracker.scheduleFrontmostPollForTesting(pid: -41000)
        await wait { gate.state.withLock { $0.entered.contains(0) } }
        let oldRead = tracker.pendingInventoryWorkForTesting
        defer { gate.gates.forEach { $0.signal() } }
        desktop.state.withLock { $0.focused = 1001 }
        tracker.handleFocusedWindowChanged(pid: -41000)
        await wait { active(0, "tabgrp-editor-a") && !active(1, "tabgrp-editor-b") }
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: -41000))
        XCTAssertEqual(gate.state.withLock { $0.inventoryReads }, 1)
        gate.gates[0].signal()
        for task in oldRead { await task.value }
        await wait { gate.state.withLock { $0.entered.contains(1) } }
        await wait { active(0, "tabgrp-editor-a") && !active(1, "tabgrp-editor-b") }
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1001")]?.status, .active)
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-1002")]?.status, .inactive)
        gate.gates[1].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertTrue(active(0, "tabgrp-editor-a"))
        XCTAssertFalse(active(1, "tabgrp-editor-b"))
        XCTAssertFalse(active(0, "tabgrp-browser-c"))
        XCTAssertEqual(gate.state.withLock { $0.inventoryReads }, 2)
        XCTAssertTrue(views.allSatisfy { $0.window == nil })
    }

    func testProcessChurnReleasesGenerationsIncludingUntrackedAndFinderProcesses() {
        let tracker = tracker(reader: LifecycleReader())
        defer { tracker.stop() }
        tracker.setFrontmostPIDForTesting(-1)
        for pid in Int32(40_000)..<41_000 {
            tracker.installFixtureForTesting(.init(pid: pid, bundleIdentifier: "test.app", appName: "App",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            tracker.terminateForTesting(pid: pid)
            tracker.terminateForTesting(pid: pid + 10_000)
        }
        tracker.installFixtureForTesting(.init(pid: 42, bundleIdentifier: "com.apple.finder", appName: "Finder",
            activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
        tracker.terminateForTesting(pid: 42)
        XCTAssertEqual(tracker.mutationGenerationCountForTesting, 0)
        XCTAssertTrue(tracker.diagnosticApps().isEmpty)
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
    }

    func testTerminatedProcessReadCannotConsumeReplacementProcessRead() async {
        let reader = LifecycleReader()
        let process = LifecycleProcess()
        let tracker = tracker(reader: reader, process: process)
        defer { tracker.stop() }
        let pid = NSRunningApplication.current.processIdentifier
        func entry(_ title: String) -> AppEntry {
            .init(pid: pid, bundleIdentifier: "test.app", appName: "App", activationPolicy: .regular,
                executablePath: nil, windowsByID: [77: .init(cgWindowID: 77, token: title, title: title,
                    bounds: CGRect(x: 40, y: 40, width: 640, height: 480), isMinimized: false, isFocused: false)],
                windowOrder: [77], isHidden: false)
        }
        tracker.installFixtureForTesting(entry("Original"))
        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)
        await waitForRead(reader)
        let old = tracker.pendingInventoryWorkForTesting
        tracker.terminateForTesting(pid: pid)
        XCTAssertEqual(tracker.mutationGenerationCountForTesting, 0)
        process.generation.withLock { $0 += 1 }
        tracker.installFixtureForTesting(entry("Replacement"))
        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        await waitForRead(reader, count: 2)
        reader.gates[0].signal()
        for task in old { await task.value }
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pid))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[77]?.title, "Replacement")
        reader.gates[1].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 1"])
        XCTAssertEqual(tracker.mutationGenerationCountForTesting, 1)
    }

    func testStandaloneNonmodalSettingsDialogsAreShownWithoutAdmittingSheetsOrUtilityPanels() async {
        let cases: [(modal: Bool?, topLevel: Bool, subrole: String, count: Int)] = [
            (false, true, kAXDialogSubrole as String, 1),
            (true, true, kAXDialogSubrole as String, 0),
            (nil, true, kAXDialogSubrole as String, 0),
            (false, false, kAXDialogSubrole as String, 0),
            (false, true, kAXFloatingWindowSubrole as String, 0)
        ]
        for sample in cases {
            let desktop = BehaviorDesktop()
            desktop.state.withLock {
                $0.windows = $0.windows.filter { $0.key == 1001 }
                $0.windows[1001]?.title = "Profiles"
                $0.subroles[1001] = sample.subrole
                $0.modalWindows[1001] = sample.modal
                if sample.topLevel { $0.topLevelWindows.insert(1001) }
            }
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [1001], onScreenWindowIDs: [1001],
                windowIDsByPID: [-41000: [1001]], alphaByWindowID: [1001: 1])
            let tracker = AppTracker(reader: AXWindowReader(accessibility: desktop), processProvider: LifecycleProcess(),
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [1001] })
            tracker.installFixtureForTesting(AppEntry(pid: -41000, bundleIdentifier: "test.SettingsApp", appName: "SettingsApp",
                activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false))
            defer { tracker.stop() }
            tracker.scheduleFrontmostPollForTesting(pid: -41000)
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            let windows = StripItem.openWindows(from: tracker.snapshot)
            XCTAssertEqual(windows.count, sample.count, "modal=\(String(describing: sample.modal)) topLevel=\(sample.topLevel) subrole=\(sample.subrole)")
            if sample.count == 1 { XCTAssertEqual(windows.first?.title, "Profiles") }
        }
    }

    private var embeddedApplication: AppTrackerWindowEligibility.Application {
        .init(bundleIdentifier: "test.Host.helper", appName: "Helper", activationPolicy: .accessory,
              executablePath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app/Contents/MacOS/Helper",
              bundleURL: URL(fileURLWithPath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app"))
    }

    private func ownedTracker(reader: any AppTrackerWindowReading, process: OwnedApplicationProcess) -> AppTracker {
        let pid = NSRunningApplication.current.processIdentifier
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [77], onScreenWindowIDs: [77],
            windowIDsByPID: [pid: [77]], alphaByWindowID: [77: 1])
        return AppTracker(reader: reader, processProvider: process,
                          cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [77] })
    }

    func testLateAdmissionCannotReplaceTheBindingOfAnAlreadyAdmittedHelper() async {
        let reader = LifecycleReader()
        let process = OwnedApplicationProcess()
        let tracker = ownedTracker(reader: reader, process: process)
        defer { reader.gates.forEach { $0.signal() }; tracker.stop() }
        process.parentGeneration.withLock { $0 = 9 }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        await waitForRead(reader)
        process.parentGeneration.withLock { $0 = 10 }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        await waitForRead(reader, count: 2)
        reader.gates[1].signal()
        await waitForFocus { tracker.snapshot.windows.count == 1 }
        XCTAssertEqual(tracker.snapshot.windows.values.first?.title, "Read 1")
        reader.gates[0].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [77])
        XCTAssertEqual(tracker.snapshot.windows.count, 1)
        XCTAssertEqual(tracker.snapshot.windows.values.first?.owningApplication?.generation,
                       ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
    }

    func testFrontmostHostPollingRefreshesItsOwnedHelper() async {
        let reader = AdmissionWindowReader()
        let process = OwnedApplicationProcess()
        let tracker = ownedTracker(reader: reader, process: process)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        tracker.setFrontmostPIDForTesting(-43000)
        reader.state.withLock { $0.focused = true }
        tracker.scheduleFrontmostPollForTesting(pid: -43000)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.values.first?.status, .active)
        XCTAssertEqual(reader.state.withLock { $0.reads }, 2)
        XCTAssertEqual(process.lookups.withLock { $0 }, 1)
    }

    func testMainApplicationTerminationRetiresItsHelperInventory() async {
        let reader = AdmissionWindowReader()
        let process = OwnedApplicationProcess()
        let tracker = ownedTracker(reader: reader, process: process)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed", application: embeddedApplication)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.count, 1)
        process.parentAlive.withLock { $0 = false }
        tracker.handleAppTerminated(pid: -43000)
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        XCTAssertTrue(tracker.diagnosticApps().isEmpty)
    }

    func testVerifiedEmbeddedHelperIsAdmittedWithoutChangingItsWindowOwner() async {
        let pid = NSRunningApplication.current.processIdentifier
        for source in ["seed", "scan", "launchRetry"] {
            let reader = AdmissionWindowReader()
            let process = OwnedApplicationProcess()
            let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [77], onScreenWindowIDs: [77],
                windowIDsByPID: [pid: [77]], alphaByWindowID: [77: 1])
            let tracker = AppTracker(reader: reader, processProvider: process,
                cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [77] })
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source, application: .init(
                bundleIdentifier: "test.Host.helper", appName: "Helper", activationPolicy: .accessory,
                executablePath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app/Contents/MacOS/Helper",
                bundleURL: URL(fileURLWithPath: "/Applications/Host/Contents/MacOS/Frameworks/Helper.app")))
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).count, 1, source)
            XCTAssertEqual(tracker.snapshot.windows.values.first?.pid, pid, source)
            XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).first?.bundleIdentifier, "test.Host", source)
            XCTAssertEqual(tracker.snapshot.windows.values.first?.bundleIdentifier, "test.Host.helper", source)
            XCTAssertFalse(process.usedMainThread.withLock { $0 }, source)
            XCTAssertEqual(process.lookups.withLock { $0 }, 1, source)
        }
    }

    func testAccessoryDashboardIsAdmittedBySeedScanAndLaunchRetry() async {
        for source in ["seed", "scan", "launchRetry"] {
            let reader = AdmissionWindowReader()
            let tracker = admissionTracker(reader: reader)
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source, application: .init(
                bundleIdentifier: "eu.exelban.Stats", appName: "Stats", activationPolicy: .accessory,
                executablePath: "/Applications/Stats.app/Contents/MacOS/Stats",
                bundleURL: URL(fileURLWithPath: "/Applications/Stats.app")))
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
            let windows = StripItem.openWindows(from: tracker.snapshot)
            XCTAssertEqual(windows.map(\.title), ["Dashboard"], source)
            XCTAssertEqual(windows.map(\.bundleIdentifier), ["eu.exelban.Stats"], source)
            XCTAssertFalse(reader.state.withLock { $0.usedMainThread }, source)
        }
    }

    func testAccessoryWindowFiltersStillRejectUtilityAndInvisibleSurfaces() async {
        for source in ["seed", "scan", "launchRetry"] {
            for kind in AdmissionWindowReader.RejectedKind.allCases {
                let reader = AdmissionWindowReader(rejected: kind)
                let tracker = admissionTracker(reader: reader)
                defer { tracker.stop() }
                tracker.runAdmissionForTesting(source: source, application: .init(
                    bundleIdentifier: "test.menubar", appName: "MenuBar", activationPolicy: .accessory,
                    executablePath: nil, bundleURL: URL(fileURLWithPath: "/Applications/MenuBar.app")))
                for task in tracker.pendingInventoryWorkForTesting { await task.value }
                XCTAssertTrue(StripItem.openWindows(from: tracker.snapshot).isEmpty, "\(source): \(kind)")
                XCTAssertTrue(tracker.diagnosticApps().isEmpty, "\(source): \(kind)")
            }
        }
    }

    func testAccessoryWindowCanReopenFromAnEventWithoutPeriodicAdmission() async {
        let reader = AdmissionWindowReader()
        let tracker = admissionTracker(reader: reader)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed", application: .init(
            bundleIdentifier: "eu.exelban.Stats", appName: "Stats", activationPolicy: .accessory,
            executablePath: nil, bundleURL: URL(fileURLWithPath: "/Applications/Stats.app")))
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        let pid = NSRunningApplication.current.processIdentifier
        XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).count, 1)
        reader.state.withLock { $0.windowID = nil }
        tracker.destroyForTesting(pid: pid, cgWindowID: 77)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertTrue(StripItem.openWindows(from: tracker.snapshot).isEmpty)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid))
        reader.state.withLock { $0.windowID = 78 }
        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(StripItem.openWindows(from: tracker.snapshot).map(\.title), ["Dashboard"])
        XCTAssertEqual(tracker.snapshot.windows.values.compactMap(\.cgWindowID), [78])
    }

    func testProhibitedSelfAndEmbeddedHelpersCannotBeAdmitted() async {
        let applications: [AppTrackerWindowEligibility.Application] = [
            .init(bundleIdentifier: "test.background", appName: "Background", activationPolicy: .prohibited,
                  executablePath: nil),
            .init(bundleIdentifier: DockWindowEligibilityPolicy.selfBundleIdentifier, appName: "ProperWM",
                  activationPolicy: .accessory, executablePath: nil,
                  bundleURL: URL(fileURLWithPath: "/Applications/ProperWM.app")),
            .init(bundleIdentifier: "com.valvesoftware.steam.helper", appName: "Steam Helper",
                  activationPolicy: .accessory, executablePath: nil, bundleURL: URL(fileURLWithPath:
                    "/Application Support/Steam/Steam.AppBundle/Steam/Contents/Frameworks/Steam Helper.app")),
            .init(bundleIdentifier: "test.helper", appName: "Helper", activationPolicy: .accessory,
                  executablePath: nil, bundleURL: URL(fileURLWithPath: "/Applications/Host.app/Contents/Helpers/Helper.app")),
            .init(bundleIdentifier: "test.unbundled", appName: "Unbundled", activationPolicy: .accessory,
                  executablePath: nil)
        ]
        for source in ["seed", "scan", "launchRetry"] {
            for application in applications {
                let reader = AdmissionWindowReader()
                let tracker = admissionTracker(reader: reader)
                defer { tracker.stop() }
                tracker.runAdmissionForTesting(source: source, application: application)
                for task in tracker.pendingInventoryWorkForTesting { await task.value }
                XCTAssertTrue(StripItem.openWindows(from: tracker.snapshot).isEmpty, source)
                XCTAssertTrue(tracker.diagnosticApps().isEmpty, source)
            }
        }
    }

    private func admissionTracker(reader: AdmissionWindowReader) -> AppTracker {
        let pid = NSRunningApplication.current.processIdentifier
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: "/unused"), maxFileSize: 1024, archiveCount: 0))
        return AppTracker(inventoryLog: log, reader: reader, processProvider: LifecycleProcess(),
                          cgSnapshotProvider: {
                              let ids = Set(reader.state.withLock { $0.windowID.map { [$0] } ?? [] })
                              return .init(allWindowIDs: ids, onScreenWindowIDs: ids, windowIDsByPID: [pid: ids],
                                           alphaByWindowID: Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }))
                          }, onScreenWindowIDsProvider: {
                              Set(reader.state.withLock { $0.windowID.map { [$0] } ?? [] })
                          })
    }

    private func tracker(reader: LifecycleReader, process: LifecycleProcess = LifecycleProcess()) -> AppTracker {
        let pid = NSRunningApplication.current.processIdentifier
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [77], onScreenWindowIDs: [77],
            windowIDsByPID: [pid: [77]], alphaByWindowID: [77: 1])
        let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
            directoryURL: URL(fileURLWithPath: "/unused"), maxFileSize: 1024, archiveCount: 0))
        return AppTracker(inventoryLog: log, reader: reader, processProvider: process,
                          cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { [77] })
    }

    private func waitForRead(_ reader: LifecycleReader, count: Int = 1) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while reader.state.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(reader.state.withLock { $0.count }, count)
    }

    func testStopRejectsSeedScanAndRetryResultsAlreadyInFlight() async {
        for source in ["seed", "scan", "launchRetry"] {
            let reader = LifecycleReader()
            let tracker = tracker(reader: reader)
            tracker.runAdmissionForTesting(source: source)
            await waitForRead(reader)
            let pending = tracker.pendingInventoryWorkForTesting
            XCTAssertFalse(pending.isEmpty)
            tracker.stop()
            reader.gates[0].signal()
            for task in pending { await task.value }
            XCTAssertTrue(tracker.diagnosticApps().isEmpty, source)
            XCTAssertTrue(tracker.snapshot.windows.isEmpty, source)
            XCTAssertTrue(tracker.lastAdmissionVerdictByPID.isEmpty, source)
            XCTAssertTrue(tracker.absenceProbeTimerPIDsForTesting.isEmpty)
        }
    }

    func testOldReadCannotOverwriteTheNextRun() async {
        for source in ["seed", "scan", "launchRetry"] {
            let reader = LifecycleReader()
            let tracker = tracker(reader: reader)
            defer { tracker.stop() }
            tracker.runAdmissionForTesting(source: source)
            await waitForRead(reader)
            let old = tracker.pendingInventoryWorkForTesting
            tracker.stop()
            tracker.runAdmissionForTesting(source: source)
            await waitForRead(reader, count: 2)
            let current = tracker.pendingInventoryWorkForTesting
            reader.gates[1].signal()
            for task in current { await task.value }
            XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 1"], source)
            reader.gates[0].signal()
            for task in old { await task.value }
            XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 1"], source)
        }
    }

    func testSeedLeavesMainActorAvailableWhileReading() async {
        let reader = LifecycleReader()
        let tracker = tracker(reader: reader)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed")
        await waitForRead(reader)
        XCTAssertFalse(reader.state.withLock { $0.usedMainThread })
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        let pending = tracker.pendingInventoryWorkForTesting
        reader.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertEqual(tracker.snapshot.windows.values.map(\.title), ["Read 0"])
    }

    func testSeedRejectsAProcessReplacedDuringTheRead() async {
        let reader = LifecycleReader()
        let process = LifecycleProcess()
        let tracker = tracker(reader: reader, process: process)
        defer { tracker.stop() }
        tracker.runAdmissionForTesting(source: "seed")
        await waitForRead(reader)
        let pending = tracker.pendingInventoryWorkForTesting
        process.generation.withLock { $0 += 1 }
        reader.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        XCTAssertTrue(tracker.diagnosticApps().isEmpty)
    }

    func testStopCancelsDelayedRetriesBeforeReading() async {
        let reader = LifecycleReader()
        let tracker = tracker(reader: reader)
        tracker.runAdmissionForTesting(source: "launchRetry", retryDelays: [60, 120])
        let pending = tracker.pendingInventoryWorkForTesting
        XCTAssertEqual(pending.count, 2)
        tracker.stop()
        for task in pending { await task.value }
        XCTAssertEqual(reader.state.withLock { $0.count }, 0)
        XCTAssertTrue(tracker.lastAdmissionVerdictByPID.isEmpty)
    }
}

private final class AdmissionWindowReader: AppTrackerWindowReading, Sendable {
    enum RejectedKind: CaseIterable {
        case empty, untitled, tiny, utility
    }
    struct State {
        var usedMainThread = false
        var windowID: CGWindowID? = 77
        var focused = false
        var reads = 0
    }
    let state = Mutex(State())
    let rejected: RejectedKind?

    init(rejected: RejectedKind? = nil) { self.rejected = rejected }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { read(pid).windowsOrEmpty }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { read(pid) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { read(pid) }

    private func read(_ pid: pid_t) -> AXWindowReadResult {
        let values = state.withLock {
            $0.usedMainThread = $0.usedMainThread || Thread.isMainThread
            $0.reads += 1
            return ($0.windowID, $0.focused)
        }
        guard rejected != .empty, let windowID = values.0 else { return .success([]) }
        return .success([AXWindowSnapshot(pid: pid, cgWindowID: windowID,
            titleRead: rejected == .untitled ? .empty : .value("Dashboard"),
            bounds: rejected == .tiny ? CGRect(x: 0, y: 0, width: 10, height: 10)
                : CGRect(x: 40, y: 40, width: 850, height: 780),
            role: kAXWindowRole as String,
            subrole: rejected == .utility ? kAXFloatingWindowSubrole as String : kAXStandardWindowSubrole as String,
            isMinimized: false, isFocusedWindow: values.1, element: AXUIElementCreateApplication(pid))])
    }
}

extension AppTracker {
    func terminateForTesting(pid: pid_t) { handleAppTerminated(pid: pid) }
    var mutationGenerationCountForTesting: Int { mutationGenerations.count }
}

@MainActor
private final class ControlledInventoryLifecycle: WindowInventoryTracking {
    let tracker: AppTracker
    var snapshots: AnyPublisher<DockSnapshot, Never> { tracker.snapshots }
    init(_ tracker: AppTracker) { self.tracker = tracker }
    func start() {}
    func stop() { tracker.stop() }
}

private final class FocusInventoryGate: Sendable {
    struct State {
        var inventoryReads = 0
        var entered = Set<Int>()
    }
    let state = Mutex(State())
    let gates = (0..<2).map { _ in DispatchSemaphore(value: 0) }
    func read(_ attribute: String) {
        if attribute == kAXWindowsAttribute as String { state.withLock { $0.inventoryReads += 1 } }
        guard attribute == kAXTitleAttribute as String else { return }
        let index = state.withLock { value -> Int? in
            let index = value.inventoryReads - 1
            guard gates.indices.contains(index), value.entered.insert(index).inserted else { return nil }
            return index
        }
        if let index { _ = gates[index].wait(timeout: .now() + 3) }
    }
}

private final class FocusLifecycleReader: AppTrackerWindowReading, Sendable {
    struct State {
        var reads = 0
        var result: AXFocusedWindowRead = .window(77)
        var usedMainThread = false
    }
    let state = Mutex(State())
    let gate = DispatchSemaphore(value: 0)
    let blockFirst: Bool
    init(blockFirst: Bool = true) { self.blockFirst = blockFirst }
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .unread(.cannotComplete) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { .unread(.cannotComplete) }
    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation {
        let observedAt = ProcessInfo.processInfo.systemUptime
        let (index, result) = state.withLock { value in
            value.reads += 1
            value.usedMainThread = value.usedMainThread || Thread.isMainThread
            return (value.reads, value.result)
        }
        if blockFirst && index == 1 { _ = gate.wait(timeout: .now() + 3) }
        return AXFocusedWindowObservation(result: result, observedAt: observedAt)
    }
}

private final class FocusListGate: Sendable {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    func read(_ attribute: String) {
        guard attribute == kAXWindowsAttribute as String else { return }
        entered.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 3)
    }
}

private final class OwnedApplicationProcess: AppTrackerProcessProviding, Sendable {
    let parentAlive = Mutex(true)
    let parentGeneration = Mutex(Int64(10))
    let lookups = Mutex(0)
    let usedMainThread = Mutex(false)
    func isAlive(pid: pid_t) -> Bool { pid != -43000 || parentAlive.withLock { $0 } }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: isAlive(pid: pid) ? (pid == -43000 ? parentGeneration.withLock { $0 } : 10) : nil, startTimeUsec: 1, bundleID: bundleID)
    }
    func applicationOwner(pid: pid_t) -> (identity: ScanAdmissionDecision.ProcessIdentity, application: AppTrackerWindowEligibility.Application)? {
        lookups.withLock { $0 += 1 }
        usedMainThread.withLock { $0 = $0 || Thread.isMainThread }
        return (identity(pid: -43000, bundleID: "test.Host"),
         .init(bundleIdentifier: "test.Host", appName: "Host", activationPolicy: .regular,
               executablePath: "/Applications/Host/Contents/MacOS/Host", bundleURL: URL(fileURLWithPath: "/Applications/Host")))
    }
}
