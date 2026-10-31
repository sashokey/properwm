import AppKit
import ApplicationServices
import XCTest

final class DiagnosticEligibilityTests: XCTestCase {
    private let policy = DockWindowEligibilityPolicy()
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func candidate(
        bid: String? = "test.app", name: String = "App", title: String? = "Window",
        role: String? = kAXStandardWindowSubrole as String, bounds: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300),
        alpha: Double? = 1, activation: NSApplication.ActivationPolicy = .regular, path: String? = nil
    ) -> DockWindowEligibilityPolicy.Candidate {
        .init(bundleIdentifier: bid, appName: name, title: title, subrole: role, bounds: bounds,
              alpha: alpha, activationPolicy: activation, executablePath: path)
    }

    func testEverySharedPolicyRejectionAndLegacyAdapter() {
        let cases: [(DockWindowEligibilityPolicy.Candidate, DockWindowEligibilityPolicy.Verdict)] = [
            (candidate(), .eligible),
            (candidate(bid: DockWindowEligibilityPolicy.selfBundleIdentifier), .selfApp),
            (candidate(alpha: 0), .transparent),
            (candidate(bid: "com.apple.notificationcenterui"), .systemSurfaceBundle),
            (candidate(bid: "com.apple.controlcenter"), .systemSurfaceBundle),
            (candidate(name: "Control Center"), .systemSurfaceAppName),
            (candidate(path: "/App/Widget.appex/file"), .systemSurfaceExtension),
            (candidate(path: "/App/DockHelper.xpc/file"), .systemSurfaceExecutable),
            (candidate(title: "Notification Center"), .systemSurfaceTitle),
            (candidate(title: "通知中心"), .systemSurfaceTitle),
            (candidate(activation: .prohibited), .prohibitedPolicy),
            (candidate(title: "", activation: .accessory), .accessoryWithoutTitleOrTooSmall),
            (candidate(bounds: .zero, activation: .accessory), .accessoryWithoutTitleOrTooSmall),
            (candidate(title: nil, role: nil), .emptyTitleNotStandardOrTooSmall),
            (candidate(title: "", bounds: .zero), .emptyTitleNotStandardOrTooSmall),
            (candidate(title: ""), .eligible),
            (candidate(bid: "com.electron.lark", title: "通知中心", activation: .prohibited), .eligible),
            (candidate(bid: "com.electron.lark", alpha: 0), .transparent)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(policy.verdict(input), expected)
            XCTAssertEqual(policy.evaluate(input), expected == .eligible ? .keep : .filter)
        }
    }

    func testEveryInventoryReasonAndBoolAdapter() {
        let cases: [(String, String?, String?, String?, Bool, DockWindowEligibilityPolicy.Verdict)] = [
            ("test.app", "Window", kAXWindowRole as String, kAXStandardWindowSubrole as String, false, .eligible),
            ("test.app", "Window", kAXWindowRole as String, kAXStandardWindowSubrole as String, true, .belowNormalLayer),
            ("com.electron.lark", "Window", "AXButton", kAXStandardWindowSubrole as String, false, .feishuNotMainWindow),
            ("com.apple.finder", "Finder", kAXWindowRole as String, kAXStandardWindowSubrole as String, false, .finderNotTrackable),
            ("test.app", "Window", "AXButton", kAXStandardWindowSubrole as String, false, .notMainWindow)
        ]
        for (bid, title, role, subrole, below, expected) in cases {
            let app = AppTrackerWindowEligibility.Application(bundleIdentifier: bid, appName: "App", activationPolicy: .regular, executablePath: nil)
            let verdict = AppTrackerWindowEligibility().verdict(title: title, role: role, subrole: subrole, bounds: frame,
                alpha: 1, isMinimized: false, isBelowNormalLayer: below, application: app)
            XCTAssertEqual(verdict, expected)
            XCTAssertEqual(AppTrackerWindowEligibility().isEligible(title: title, role: role, subrole: subrole,
                bounds: frame, alpha: 1, isMinimized: false, isBelowNormalLayer: below, application: app), expected == .eligible)
        }
    }
}

@MainActor
final class DiagnosticSessionTests: XCTestCase {
    func testThreeVisibilitySourcesCancellationTimeoutDedupAndRingLimit() {
        var history = DiagnosticVisibilityHistory()
        for source in ["ax", "green-button-prediction", "space-intent-right"] {
            XCTAssertNotNil(history.noteVisibilityChange(unit: source, screen: "display", previousVisible: true,
                visible: false, reasons: [.fullscreenTransitionPending], source: source))
            XCTAssertNil(history.noteVisibilityChange(unit: source, screen: "display", previousVisible: false,
                visible: false, reasons: [.fullscreen], source: "confirmation"))
            XCTAssertNotNil(history.noteVisibilityChange(unit: source, screen: "display", previousVisible: false,
                visible: true, reasons: [], source: "intent-cancel-timeout"))
        }
        XCTAssertEqual(history.changes.count, 6)
        XCTAssertEqual(history.changes.first?.reasons, ["fullscreenTransitionPending"])
        for i in 0..<60 {
            history.noteVisibilityChange(unit: "loop", screen: "display", previousVisible: i % 2 != 0,
                visible: i % 2 == 0, reasons: [], source: "timeout-recovery")
        }
        XCTAssertEqual(history.changes.count, 40)
        XCTAssertTrue(history.changes.allSatisfy { $0.source == "timeout-recovery" })
    }
}

private struct DiagnosticFixtureReader: AppTrackerWindowReading {
    let unread: Bool
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        precondition(!Thread.isMainThread)
        return result
    }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { result }
    private var result: AXWindowReadResult { unread ? .unread(.cannotComplete) : .success([]) }
}

private struct DiagnosticFixtureProcess: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: 1, startTimeUsec: 0, bundleID: bundleID)
    }
}

@MainActor
final class DiagnosticAdmissionTests: XCTestCase {
    func testMinimizedRawReadDistinguishesFalseFromUnread() {
        for raw in [nil, false, true] as [Bool?] {
            let snapshot = AXWindowSnapshot(pid: 4242, cgWindowID: 7, titleRead: .empty, bounds: nil,
                role: nil, subrole: nil, isMinimized: raw ?? false, isFocusedWindow: false,
                element: AXUIElementCreateApplication(4242), isMinimizedRead: raw)
            XCTAssertEqual(snapshot.isMinimizedRead, raw)
            XCTAssertEqual(snapshot.isMinimized, raw ?? false)
        }
    }

    func testCreatedAtSurvivesContinuationAndNewSeatUsesReadTime() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let oldTime = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let tracker = AppTracker(processProvider: DiagnosticFixtureProcess(), onScreenWindowIDsProvider: { [] })
        let seat = WindowEntry(cgWindowID: 7, token: "old-seat", title: "Old", bounds: frame,
            isMinimized: false, isFocused: false, everSeenVisible: true, createdAt: oldTime)
        tracker.installFixtureForTesting(.init(pid: 4242, bundleIdentifier: "test.app", appName: "App",
            activationPolicy: .regular, executablePath: nil, windowsByID: [7: seat], windowOrder: [7], isHidden: false))
        let snapshots = [UInt32(7), 9].map { id in
            AXWindowSnapshot(pid: 4242, cgWindowID: id, titleRead: .value("Updated"),
                bounds: id == 7 ? frame : CGRect(x: 500, y: 500, width: 500, height: 400),
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(4242))
        }
        _ = tracker.reconcileFixtureForTesting(pid: 4242,
            cgSnapshot: .init(allWindowIDs: [7, 9], onScreenWindowIDs: [7, 9], windowIDsByPID: [4242: [7, 9]],
                              alphaByWindowID: [7: 1, 9: 1]), now: now, eligible: snapshots, readOutcome: .success(count: 2))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: 4242)?.windowsByID[7]?.createdAt, oldTime)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: 4242)?.windowsByID[9]?.createdAt, now)
        tracker.stop()
    }

    func testRealSeedScanAndLaunchRetryEntrancesRecordWithInventoryLogOff() async {
        for source in ["seed", "scan", "launchRetry"] {
            for unread in [false, true] {
                let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
                    directoryURL: URL(fileURLWithPath: "/unused"), maxFileSize: 1024, archiveCount: 0))
                XCTAssertFalse(log.isEnabled)
                let tracker = AppTracker(inventoryLog: log, reader: DiagnosticFixtureReader(unread: unread),
                    processProvider: DiagnosticFixtureProcess(), cgSnapshotProvider: { .failed }, onScreenWindowIDsProvider: { [] })
                tracker.runAdmissionForTesting(source: source)
                let pid = NSRunningApplication.current.processIdentifier
                for _ in 0..<1_000 {
                    if tracker.lastAdmissionVerdictByPID[pid] != nil { break }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                XCTAssertEqual(tracker.lastAdmissionVerdictByPID[pid]?.source, source)
                XCTAssertEqual(tracker.lastAdmissionVerdictByPID[pid]?.verdict, unread ? "skipUnread" : "skipNoEligible")
                XCTAssertTrue(tracker.diagnosticApps().isEmpty)
                tracker.stop()
                XCTAssertTrue(tracker.lastAdmissionVerdictByPID.isEmpty)
            }
        }
    }
}
