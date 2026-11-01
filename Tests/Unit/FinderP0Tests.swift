import AppKit
import CoreGraphics
import XCTest

final class FinderP0Tests: XCTestCase {
    func testObservationKindMergePrefersActionableState() {
        var merged: SystemObservation.ObservationKind?

        for kind in [
            SystemObservation.ObservationKind.unchanged,
            .unhidden,
            .minimized,
            .hidden
        ] {
            merged = ObservationKindMergeRule.preferred(merged, kind)
        }

        XCTAssertEqual(merged, .hidden)
    }

    func testObservationKindMergeKeepsMinimizedOverUnchanged() {
        let merged = ObservationKindMergeRule.preferred(.minimized, .unchanged)
        XCTAssertEqual(merged, .minimized)
    }

    func testToggleUsesSnapshotStatus() {
        let id = WindowID(rawValue: "cg-1")
        let frontmostPlanner = LifecycleActionPlanner(isAppFrontmost: { _ in true })
        let backgroundPlanner = LifecycleActionPlanner(isAppFrontmost: { _ in false })
        let activeSnapshot = snapshot(windowID: id, status: .active)
        let inactiveSnapshot = snapshot(windowID: id, status: .inactive)
        let minimizedSnapshot = snapshot(windowID: id, status: .minimized)

        XCTAssertEqual(
            frontmostPlanner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .minimizeWindow
        )
        XCTAssertEqual(
            backgroundPlanner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .activateWindow
        )
        XCTAssertEqual(
            backgroundPlanner.plan(intent: .toggle(id), snapshot: inactiveSnapshot).kind,
            .activateWindow
        )
        XCTAssertEqual(
            backgroundPlanner.plan(intent: .toggle(id), snapshot: minimizedSnapshot).kind,
            .activateWindow
        )
    }

    func testToggleAlternatesViaOptimisticStateWhileSnapshotIsStale() {
        let id = WindowID(rawValue: "cg-optimistic")
        let planner = LifecycleActionPlanner(isAppFrontmost: { _ in true })
        let staleActiveSnapshot = snapshot(windowID: id, status: .active)

        let afterMinimize = [
            id.rawValue: OptimisticWindowState(status: .minimized, createdAt: Date())
        ]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: staleActiveSnapshot, optimisticStates: afterMinimize).kind,
            .activateWindow
        )

        let afterActivate = [
            id.rawValue: OptimisticWindowState(status: .active, createdAt: Date())
        ]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: staleActiveSnapshot, optimisticStates: afterActivate).kind,
            .minimizeWindow
        )
    }

    func testToggleWithStaleOptimisticActiveButAppNotFrontmostPlansActivate() {
        let id = WindowID(rawValue: "cg-stale-optimistic")
        let planner = LifecycleActionPlanner(isAppFrontmost: { _ in false })
        let lingering = [
            id.rawValue: OptimisticWindowState(status: .active, createdAt: Date())
        ]

        for status in [WindowStatus.active, .inactive] {
            XCTAssertEqual(
                planner.plan(
                    intent: .toggle(id),
                    snapshot: snapshot(windowID: id, status: status),
                    optimisticStates: lingering
                ).kind,
                .activateWindow
            )
        }
    }

    func testToggleDoesNotMinimizeAppLevelFallbacks() {
        let id = WindowID(rawValue: "app-com.electron.lark")
        let planner = LifecycleActionPlanner()
        let activeSnapshot = snapshot(windowID: id, status: .active)

        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .activateWindow
        )
    }

    func testToggleOnHiddenWindowPlansActivate() {
        let id = WindowID(rawValue: "cg-hidden")
        let planner = LifecycleActionPlanner()
        let hiddenSnapshot = snapshot(windowID: id, status: .hidden)

        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: hiddenSnapshot).kind,
            .activateWindow
        )
    }

    func testMinimizeFeedbackAcceptsTemporaryDisappearance() {
        let id = WindowID(rawValue: "cg-2")
        var feedback = IntentFeedbackState()
        feedback.begin(windowID: id.rawValue, action: .minimize, at: Date())

        feedback.reconcile(snapshot: snapshot(windowID: id, status: .disappeared), now: Date())

        XCTAssertEqual(feedback.entriesByWindowID[id.rawValue]?.phase, .success)
    }

    func testActivateFeedbackSucceedsImmediatelyWhenExecutionSucceeds() {
        let id = WindowID(rawValue: "cg-activate")
        var feedback = IntentFeedbackState()
        feedback.begin(windowID: id.rawValue, action: .activate, at: Date())

        feedback.markSucceededImmediatelyIfNeeded(windowID: id.rawValue, action: .activate, at: Date())

        XCTAssertEqual(feedback.entriesByWindowID[id.rawValue]?.phase, .success)
    }

    func testActivateFeedbackDoesNotFlipBackToFailureAfterInactiveObservation() {
        let id = WindowID(rawValue: "cg-activate")
        var feedback = IntentFeedbackState()
        let now = Date()
        feedback.begin(windowID: id.rawValue, action: .activate, at: now)
        feedback.markSucceededImmediatelyIfNeeded(windowID: id.rawValue, action: .activate, at: now)

        feedback.reconcile(
            snapshot: snapshot(windowID: id, status: .inactive),
            now: now.addingTimeInterval(0.5)
        )

        XCTAssertEqual(feedback.entriesByWindowID[id.rawValue]?.phase, .success)
    }

    func testAdmissionGateRejectsUnknownAXOnlyCandidate() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .accessibility,
            pid: 2001,
            title: "Unknown AX Window",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .rejected)
        XCTAssertEqual(decision.reason, "accessibility-orphan-inventory-required")
    }

    func testAdmissionGateAcceptsInventoryCandidate() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .appWindowInventory,
            pid: 2101,
            title: "Inventory Window",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .accepted)
        XCTAssertEqual(decision.reason, "app-window-inventory")
    }

    func testAdmissionGateRejectsCGOrphanWhenInventoryMainlineIsAvailable() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .coreGraphics,
            pid: 2201,
            cgWindowID: 9001,
            title: "CG Orphan",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now, inventoryMainlineAvailable: true)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .rejected)
        XCTAssertEqual(decision.reason, "cg-orphan-inventory-required")
    }

    func testAdmissionGateAcceptsCGWhenInventoryMainlineIsUnavailable() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .coreGraphics,
            pid: 2301,
            cgWindowID: 9002,
            title: "CG Fallback",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now, inventoryMainlineAvailable: false)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .accepted)
        XCTAssertEqual(decision.reason, "cg-permission-fallback")
    }

    func testAdmissionGateAcceptsCGWhenItMatchesExistingInventoryWindow() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let id = WindowID(rawValue: "inventory-window")
        let snapshot = DockSnapshot(
            windows: [
                id: WindowRecord(
                    id: id,
                    appID: AppID(rawValue: "com.example.app"),
                    pid: 2401,
                    bundleIdentifier: "com.example.app",
                    title: "Existing",
                    bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
                    status: .inactive
                )
            ],
            orderedWindowIDs: [id]
        )
        let observation = observation(
            timestamp: now,
            source: .coreGraphics,
            pid: 2401,
            cgWindowID: 9003,
            title: "Existing",
            bounds: CGRect(x: 104, y: 103, width: 500, height: 400)
        )

        gate.beginRound(at: now, inventoryMainlineAvailable: true)
        let decision = gate.decide(observation: observation, snapshot: snapshot)

        XCTAssertEqual(decision.kind, .accepted)
        XCTAssertEqual(decision.reason, "matches-existing-window")
    }

    func testIdentityBindsCGToExistingInventoryWindow() {
        let identity = WindowIdentityEngine()
        let now = Date()
        let inventory = observation(
            timestamp: now,
            source: .appWindowInventory,
            pid: 2501,
            title: "Editor",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        let inventoryDecision = identity.identify(observation: inventory)

        let cg = observation(
            timestamp: now.addingTimeInterval(0.1),
            source: .coreGraphics,
            pid: 2501,
            cgWindowID: 9101,
            title: "Editor",
            bounds: CGRect(x: 106, y: 104, width: 500, height: 400)
        )
        let cgDecision = identity.identify(observation: cg)

        XCTAssertEqual(cgDecision.windowID, inventoryDecision.windowID)
        XCTAssertEqual(cgDecision.reason, "cg-bound-to-inventory")
    }

    func testIdentityDoesNotGuessCGBindingForAmbiguousSameTitleWindows() {
        let identity = WindowIdentityEngine()
        let now = Date()
        let first = observation(
            timestamp: now,
            source: .appWindowInventory,
            pid: 2601,
            title: "zsh",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        let second = observation(
            timestamp: now.addingTimeInterval(0.01),
            source: .appWindowInventory,
            pid: 2601,
            title: "zsh",
            bounds: CGRect(x: 160, y: 160, width: 500, height: 400)
        )
        _ = identity.identify(observation: first)
        _ = identity.identify(observation: second)

        let cg = observation(
            timestamp: now.addingTimeInterval(0.1),
            source: .coreGraphics,
            pid: 2601,
            cgWindowID: 9102,
            title: "zsh",
            bounds: CGRect(x: 130, y: 130, width: 500, height: 400)
        )
        let cgDecision = identity.identify(observation: cg)

        XCTAssertEqual(cgDecision.windowID, WindowID(rawValue: "cg-9102"))
        XCTAssertEqual(cgDecision.reason, "cg-window-id")
    }

    func testIdentityMatchesRetainedMinimizedWindowAfterLongGap() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-minimized")
        let bounds = CGRect(x: 100, y: 120, width: 700, height: 500)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2701,
                bundleIdentifier: "com.example.editor",
                title: "Quarterly.ai",
                bounds: bounds,
                status: .minimized
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(12 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2701,
            bundleIdentifier: "com.example.editor",
            title: "Quarterly.ai",
            bounds: CGRect(x: 108, y: 124, width: 700, height: 500),
            isMinimized: true
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "retained-seat-title-frame")
    }

    func testIdentityMatchesRetainedWindowByUniqueFrameWhenTitleChanged() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-renamed")
        let bounds = CGRect(x: 80, y: 90, width: 640, height: 420)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2702,
                bundleIdentifier: "com.example.design",
                title: "Draft.ai",
                bounds: bounds,
                status: .disappeared
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2702,
            bundleIdentifier: "com.example.design",
            title: "Draft.ai @ 125%",
            bounds: CGRect(x: 82, y: 92, width: 640, height: 420)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "retained-seat-frame")
    }

    func testIdentityDoesNotGuessRetainedWindowWhenFrameCandidatesAreAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "cg-retained-first")
        let secondID = WindowID(rawValue: "cg-retained-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2703,
                bundleIdentifier: "com.example.notes",
                title: "Old A",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
                status: .minimized
            ),
            windowRecord(
                id: secondID,
                pid: 2703,
                bundleIdentifier: "com.example.notes",
                title: "Old B",
                bounds: CGRect(x: 112, y: 108, width: 600, height: 400),
                status: .hidden
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2703,
            bundleIdentifier: "com.example.notes",
            title: "Renamed",
            bounds: CGRect(x: 106, y: 104, width: 600, height: 400)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityDoesNotMatchRetainedWindowFromDifferentProcess() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-other-process")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2704,
                bundleIdentifier: "com.example.editor",
                title: "Same Title",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
                status: .minimized
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2705,
            bundleIdentifier: "com.example.editor",
            title: "Same Title",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityDoesNotMatchClosedPendingRetainedWindow() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-closed")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2706,
                bundleIdentifier: "com.example.editor",
                title: "Closed Title",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
                status: .closedPending
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2706,
            bundleIdentifier: "com.example.editor",
            title: "Closed Title",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityMatchesRetainedWindowByUniqueTitleWhenFrameMoved() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-moved")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2707,
                bundleIdentifier: "com.example.photo",
                title: "Poster.psd",
                bounds: CGRect(x: 0, y: 490, width: 2500, height: 1410),
                status: .minimized
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2707,
            bundleIdentifier: "com.example.photo",
            title: "Poster.psd",
            bounds: CGRect(x: 0, y: 30, width: 2500, height: 1410)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "retained-seat-title")
    }

    func testIdentityDoesNotGuessRetainedTitleOnlyWhenAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "cg-retained-title-first")
        let secondID = WindowID(rawValue: "cg-retained-title-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2708,
                bundleIdentifier: "com.example.finderlike",
                title: "Downloads",
                bounds: CGRect(x: 100, y: 100, width: 700, height: 500),
                status: .minimized
            ),
            windowRecord(
                id: secondID,
                pid: 2708,
                bundleIdentifier: "com.example.finderlike",
                title: "Downloads",
                bounds: CGRect(x: 900, y: 100, width: 700, height: 500),
                status: .hidden
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2708,
            bundleIdentifier: "com.example.finderlike",
            title: "Downloads",
            bounds: CGRect(x: 500, y: 500, width: 700, height: 500)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityMatchesActiveWindowFromSnapshotAfterLongGap() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-active")
        let bounds = CGRect(x: 120, y: 140, width: 900, height: 700)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2710,
                bundleIdentifier: "com.example.browser",
                title: "Inbox",
                bounds: bounds,
                status: .active
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(10 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2710,
            bundleIdentifier: "com.example.browser",
            title: "Inbox",
            bounds: CGRect(x: 130, y: 146, width: 900, height: 700)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-title-frame")
    }

    func testIdentityMatchesActiveWindowByUniqueFrameWhenTitleChanged() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-renamed")
        let bounds = CGRect(x: 220, y: 240, width: 1000, height: 760)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2711,
                bundleIdentifier: "com.example.design",
                title: "Draft.ai @ 50%",
                bounds: bounds,
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .titleChanged,
            source: .appWindowInventory,
            pid: 2711,
            bundleIdentifier: "com.example.design",
            title: "Final.ai @ 125%",
            bounds: CGRect(x: 224, y: 244, width: 1000, height: 760)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-frame")
    }

    func testIdentityMatchesActiveWindowByUniqueTitleWhenFrameMoved() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-moved")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2715,
                bundleIdentifier: "com.example.finder",
                title: "Downloads",
                bounds: CGRect(x: 1170, y: 705, width: 1034, height: 436),
                status: .active
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2715,
            bundleIdentifier: "com.example.finder",
            title: "Downloads",
            bounds: CGRect(x: 1446, y: 661, width: 1034, height: 436)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-title")
    }

    func testIdentityDoesNotGuessActiveWindowWhenFrameCandidatesAreAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "ax-existing-first")
        let secondID = WindowID(rawValue: "ax-existing-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2712,
                bundleIdentifier: "com.example.terminal",
                title: "Old A",
                bounds: CGRect(x: 300, y: 320, width: 600, height: 420),
                status: .active
            ),
            windowRecord(
                id: secondID,
                pid: 2712,
                bundleIdentifier: "com.example.terminal",
                title: "Old B",
                bounds: CGRect(x: 308, y: 328, width: 600, height: 420),
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2712,
            bundleIdentifier: "com.example.terminal",
            title: "Renamed",
            bounds: CGRect(x: 304, y: 324, width: 600, height: 420)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityDoesNotGuessActiveTitleOnlyWhenAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "ax-existing-title-first")
        let secondID = WindowID(rawValue: "ax-existing-title-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2716,
                bundleIdentifier: "com.example.browser",
                title: "Inbox",
                bounds: CGRect(x: 100, y: 100, width: 900, height: 700),
                status: .active
            ),
            windowRecord(
                id: secondID,
                pid: 2716,
                bundleIdentifier: "com.example.browser",
                title: "Inbox",
                bounds: CGRect(x: 1200, y: 100, width: 900, height: 700),
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2716,
            bundleIdentifier: "com.example.browser",
            title: "Inbox",
            bounds: CGRect(x: 600, y: 600, width: 900, height: 700)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityBindsCGToExistingActiveSnapshotAfterLongGap() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-cg")
        let bounds = CGRect(x: 420, y: 440, width: 1100, height: 800)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2713,
                bundleIdentifier: "com.example.editor",
                title: "Notes",
                bounds: bounds,
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(11 * 60 * 60),
            kind: .unchanged,
            source: .coreGraphics,
            pid: 2713,
            bundleIdentifier: "com.example.editor",
            cgWindowID: 9301,
            title: "Notes",
            bounds: CGRect(x: 424, y: 442, width: 1100, height: 800)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-title-frame")
    }

    func testIdentityDoesNotTreatAppLevelFallbackAsLiveWindowSeat() {
        let identity = WindowIdentityEngine()
        let appLevelID = WindowID(rawValue: "app-com.example.chat")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: appLevelID,
                pid: 2714,
                bundleIdentifier: "com.example.chat",
                title: "Chat",
                bounds: CGRect(x: 520, y: 540, width: 700, height: 500),
                status: .active
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2714,
            bundleIdentifier: "com.example.chat",
            title: "Chat",
            bounds: CGRect(x: 520, y: 540, width: 700, height: 500)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, appLevelID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testRoundAnomalyFuseRejectsCandidateExplosion() {
        let fuse = ObservationRoundAnomalyFuse()
        let snapshot = snapshot(windowCount: 2)
        var observations: [SystemObservation] = []

        for index in 0..<60 {
            observations.append(
                observation(
                    source: .accessibility,
                    pid: Int32(3000 + index),
                    title: "System Surface \(index)",
                    bounds: CGRect(
                        x: CGFloat(index * 10),
                        y: CGFloat(index * 8),
                        width: 180,
                        height: 120
                    )
                )
            )
        }

        let decision = fuse.decide(observations: observations, snapshot: snapshot)

        XCTAssertEqual(decision.kind, ObservationRoundAdmissionKind.rejected)
        XCTAssertEqual(decision.reason, "count-spike")
        XCTAssertEqual(decision.baselineCount, 2)
        XCTAssertEqual(decision.candidateCount, 60)
    }

    func testRoundAnomalyFuseAcceptsPlausibleRound() {
        let fuse = ObservationRoundAnomalyFuse()
        let snapshot = snapshot(windowCount: 2)
        var observations: [SystemObservation] = []

        for index in 0..<5 {
            observations.append(
                observation(
                    source: .accessibility,
                    pid: Int32(4000 + index),
                    title: "Real Window \(index)",
                    bounds: CGRect(
                        x: CGFloat(index * 20),
                        y: CGFloat(index * 16),
                        width: 500,
                        height: 400
                    )
                )
            )
        }

        let decision = fuse.decide(observations: observations, snapshot: snapshot)

        XCTAssertEqual(decision.kind, ObservationRoundAdmissionKind.accepted)
        XCTAssertEqual(decision.reason, "plausible-round")
    }

    func testWindowEligibilityFiltersTransparentWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Real Window",
                    alpha: 0,
                    activationPolicy: .regular
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersTaskbarSelfAppWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: DockWindowEligibilityPolicy.selfBundleIdentifier,
                    appName: "任务条调试台",
                    title: "任务条调试台",
                    activationPolicy: .regular,
                    executablePath: "/Applications/ProperWM.app/Contents/MacOS/ProperWM"
                )
            ),
            .filter
        )
    }

    func testAXTaskbarWindowRulesKeepsStandardWindows() {
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            .mainWindow
        )
    }

    func testAXTaskbarWindowRulesAllowsMissingSubroleForReasonableWindow() {
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(
                role: "AXWindow",
                subrole: nil,
                bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            .unconfirmedMainWindow
        )
    }

    func testAXTaskbarWindowRulesRejectsMissingSubroleForTinyWindow() {
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(
                role: "AXWindow",
                subrole: nil,
                bounds: CGRect(x: 0, y: 0, width: 79, height: 40)
            ),
            .rejected
        )
    }

    func testAXTaskbarWindowRulesRejectsSheetsDialogsAndNonWindows() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertEqual(
            AXTaskbarWindowRules.decision(role: "AXWindow", subrole: "AXSheet", bounds: bounds),
            .rejected
        )
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(role: "AXWindow", subrole: "AXDialog", bounds: bounds),
            .rejected
        )
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(role: "AXGroup", subrole: "AXStandardWindow", bounds: bounds),
            .rejected
        )
    }

    func testWindowEligibilityKeepsUntitledStandardRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        for title in [nil, "", " \n\t"] as [String?] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: title,
                        subrole: kAXStandardWindowSubrole as String,
                        bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                        activationPolicy: .regular
                    )
                ),
                .keep
            )
        }
    }

    func testWindowEligibilityAppliesMinimumFrameToUntitledStandardRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: nil,
                    subrole: kAXStandardWindowSubrole as String,
                    bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
                    activationPolicy: .regular
                )
            ),
            .keep
        )

        for bounds in [
            CGRect(x: 0, y: 0, width: 79, height: 40),
            CGRect(x: 0, y: 0, width: 80, height: 39)
        ] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: nil,
                        subrole: kAXStandardWindowSubrole as String,
                        bounds: bounds,
                        activationPolicy: .regular
                    )
                ),
                .filter
            )
        }
    }

    func testWindowEligibilityRejectsUntitledRegularWindowsWithoutStandardSubrole() {
        let policy = DockWindowEligibilityPolicy()

        for subrole in [nil, kAXDialogSubrole as String] as [String?] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: nil,
                        subrole: subrole,
                        activationPolicy: .regular
                    )
                ),
                .filter
            )
        }
    }

    func testWindowEligibilityDoesNotExtendUntitledStandardRuleBeyondRegularApps() {
        let policy = DockWindowEligibilityPolicy()

        for activationPolicy in [NSApplication.ActivationPolicy.accessory, .prohibited] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: nil,
                        subrole: kAXStandardWindowSubrole as String,
                        activationPolicy: activationPolicy
                    )
                ),
                .filter
            )
        }
    }

    func testAppTrackerEligibilityKeepsOnlyFullyQualifiedUntitledStandardWindow() {
        let eligibility = AppTrackerWindowEligibility()
        let application = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.apple.systempreferences",
            appName: "System Settings",
            activationPolicy: .regular,
            executablePath: "/System/Applications/System Settings.app/Contents/MacOS/System Settings"
        )

        XCTAssertTrue(
            eligibility.isEligible(
                title: "",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: application
            )
        )
    }

    func testAppTrackerEligibilityRejectsBelowNormalLayerWindowsForEveryApp() {
        let eligibility = AppTrackerWindowEligibility()
        func eligible(bundleID: String, title: String, below: Bool) -> Bool {
            eligibility.isEligible(
                title: title,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 16, y: 30, width: 344, height: 359),
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: below,
                application: AppTrackerWindowEligibility.Application(
                    bundleIdentifier: bundleID,
                    appName: "Fixture",
                    activationPolicy: .regular,
                    executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture"
                )
            )
        }

        XCTAssertTrue(eligible(bundleID: "com.jian.Widgetify", title: "", below: false))
        XCTAssertFalse(eligible(bundleID: "com.jian.Widgetify", title: "", below: true))
        XCTAssertFalse(eligible(bundleID: "com.jian.Widgetify", title: "Clock", below: true))
        XCTAssertFalse(eligible(bundleID: "com.feishu.app", title: "飞书", below: true))
        XCTAssertFalse(eligible(bundleID: "com.apple.finder", title: "Documents", below: true))
    }

    func testAppTrackerEligibilityAppliesMetadataDenyFiltersBeforeUntitledAdmission() {
        let eligibility = AppTrackerWindowEligibility()
        let frame = CGRect(x: 0, y: 0, width: 723, height: 626)
        let normal = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.example.app",
            appName: "Example",
            activationPolicy: .regular,
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let extensionProcess = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.example.share",
            appName: "Share Extension",
            activationPolicy: .regular,
            executablePath: "/Applications/Example.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share"
        )
        let notificationCenter = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.apple.notificationcenterui",
            appName: "Notification Center",
            activationPolicy: .regular,
            executablePath: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
        )

        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: frame,
                alpha: 0,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: normal
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: frame,
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: extensionProcess
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: frame,
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: notificationCenter
            )
        )
    }

    func testAppTrackerEligibilityDoesNotLetNilBundleBypassUntitledSubroleGate() {
        let eligibility = AppTrackerWindowEligibility()
        let application = AppTrackerWindowEligibility.Application(
            bundleIdentifier: nil,
            appName: "Unknown",
            activationPolicy: .regular,
            executablePath: nil
        )

        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: nil,
                bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: application
            )
        )
    }

    func testAppTrackerEligibilityFiltersTransparentFeishuWindowBeforeShortcut() {
        let eligibility = AppTrackerWindowEligibility()
        let application = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.electron.lark",
            appName: "Feishu",
            activationPolicy: .regular,
            executablePath: "/Applications/Feishu.app/Contents/MacOS/Feishu"
        )

        XCTAssertFalse(
            eligibility.isEligible(
                title: "Feishu",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                alpha: 0,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: application
            )
        )
    }

    func testWindowEligibilityKeepsTitledSmallRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Small Real Window",
                    bounds: CGRect(x: 0, y: 0, width: 30, height: 20),
                    activationPolicy: .regular
                )
            ),
            .keep
        )
    }

    func testWindowEligibilityFiltersProhibitedWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(candidate(title: "Background Window", activationPolicy: .prohibited)),
            .filter
        )
    }

    func testWindowEligibilityKeepsTitledAccessoryWindowWithReasonableFrame() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Agent Window",
                    bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
                    activationPolicy: .accessory
                )
            ),
            .keep
        )
    }

    func testWindowEligibilityFiltersSmallAccessoryWindow() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Tiny Agent Window",
                    bounds: CGRect(x: 0, y: 0, width: 79, height: 40),
                    activationPolicy: .accessory
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityKeepsUntitledFeishuFallbackCandidate() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.electron.lark",
                    title: nil,
                    activationPolicy: .regular
                )
            ),
            .keep
        )
    }

    func testWindowEligibilityFiltersNotificationCenterByTitle() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(candidate(title: "Notification Center", activationPolicy: .regular)),
            .filter
        )
        XCTAssertEqual(
            policy.evaluate(candidate(title: "通知中心", activationPolicy: .regular)),
            .filter
        )
    }

    func testWindowEligibilityFiltersNotificationCenterByBundleID() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.notificationcenterui",
                    appName: "Notification Center",
                    title: "Weather",
                    activationPolicy: .regular
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersLocalizedNotificationCenterAXCandidate() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.notificationcenterui",
                    appName: "通知中心",
                    title: "天气预报",
                    bounds: CGRect(x: 188, y: 38, width: 180, height: 180),
                    activationPolicy: .accessory,
                    executablePath: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersAppExtensionWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Share Extension",
                    activationPolicy: .regular,
                    executablePath: "/System/Applications/App.app/Contents/PlugIns/ShareExtension.appex/Contents/MacOS/ShareExtension"
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityAppliesSystemFiltersBeforeUntitledStandardRule() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.notificationcenterui",
                    appName: "Notification Center",
                    title: nil,
                    subrole: kAXStandardWindowSubrole as String,
                    activationPolicy: .regular
                )
            ),
            .filter
        )
        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: nil,
                    subrole: kAXStandardWindowSubrole as String,
                    activationPolicy: .regular,
                    executablePath: "/System/Applications/App.app/Contents/PlugIns/ShareExtension.appex/Contents/MacOS/ShareExtension"
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersWidgetAndSystemServiceExecutables() {
        let policy = DockWindowEligibilityPolicy()

        let paths = [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService",
            "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod",
            "/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper",
            "/System/Library/CoreServices/Dock.app/Contents/XPCServices/com.apple.dock.extra.xpc/Contents/MacOS/com.apple.dock.extra",
            "/System/Library/CoreServices/ControlCenter.app/Contents/XPCServices/ControlCenterHelper.xpc/Contents/MacOS/ControlCenterHelper"
        ]

        for path in paths {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: "System Panel",
                        activationPolicy: .regular,
                        executablePath: path
                    )
                ),
                .filter
            )
        }
    }

    func testWindowEligibilityKeepsSpotlightAccessoryWindow() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.Spotlight",
                    appName: "Spotlight",
                    title: "Spotlight",
                    bounds: CGRect(x: 0, y: 0, width: 680, height: 80),
                    activationPolicy: .accessory,
                    executablePath: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"
                )
            ),
            .keep
        )
    }

    func testFinderTrackableWindowFiltering() {
        let bounds = CGRect(x: 10, y: 10, width: 400, height: 300)

        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "codex-finder-test-alpha-20260505",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "访达",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Preview",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "Documents",
                role: "AXWindow",
                subrole: nil,
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Downloads",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: nil,
                isMinimized: false
            )
        )
    }

    func testFinderTrackableAdmitsMinimizedDialogSubroleOnly() {
        let bounds = CGRect(x: 297, y: 611, width: 1227, height: 504)

        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXSheet",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "访达",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: CGRect(x: 0, y: 0, width: 30, height: 30),
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXFloatingWindow",
                bounds: bounds,
                isMinimized: true
            )
        )
    }

    func testAppTrackerEligibilityAdmitsMinimizedFinderDialogButNotOtherApps() {
        let eligibility = AppTrackerWindowEligibility()
        let bounds = CGRect(x: 297, y: 611, width: 1227, height: 504)
        let finder = AppTrackerWindowEligibility.Application(
            bundleIdentifier: FinderWindowRules.bundleIdentifier,
            appName: "Finder",
            activationPolicy: .regular,
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        )
        let other = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            activationPolicy: .regular,
            executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"
        )

        XCTAssertTrue(
            eligibility.isEligible(
                title: "Backup",
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                bounds: bounds,
                alpha: 1,
                isMinimized: true,
                isBelowNormalLayer: false,
                application: finder
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: "Backup",
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                bounds: bounds,
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: finder
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: "Untitled",
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                bounds: bounds,
                alpha: 1,
                isMinimized: true,
                isBelowNormalLayer: false,
                application: other
            )
        )
    }

    func testStripItemsMergeNativeTabGroupWithIdenticalFrame() {
        let frame = CGRect(x: 172, y: 87, width: 1191, height: 831)
        let tabA = WindowRecord(
            id: WindowID(rawValue: "cgw-240522"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "ob 协作",
            bounds: frame,
            status: .inactive,
            cgWindowID: 240522,
            groupID: "tabgrp-30201-s1"
        )
        let tabB = WindowRecord(
            id: WindowID(rawValue: "cgw-249469"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "程序坞-规划",
            bounds: frame,
            status: .active,
            cgWindowID: 249469,
            groupID: "tabgrp-30201-s1"
        )

        let items = StripItem.openWindows(from: retainedSnapshot(tabA, tabB))

        XCTAssertEqual(items.count, 1)
        let chip = items[0]
        XCTAssertEqual(chip.id, "tabgrp-30201-s1")
        XCTAssertEqual(chip.actionWindowID, "cgw-249469")
        XCTAssertEqual(chip.title, "程序坞-规划")
    }

    func testStripItemsBackgroundedTabGroupRepresentsVisibleTab() {
        let frame = CGRect(x: 82, y: 107, width: 1191, height: 809)
        let bgLow = WindowRecord(   // 最小 cgID = anchor，但它是后台（最小化）标签
            id: WindowID(rawValue: "cgw-249469"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "程序坞-规划",
            bounds: frame,
            status: .minimized,
            cgWindowID: 249469,
            groupID: "tabgrp-30201-s1"
        )
        let visible = WindowRecord(  // 唯一可见标签（min=0 → .inactive，因 app 非前台）
            id: WindowID(rawValue: "cgw-254022"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "发生的",
            bounds: frame,
            status: .inactive,
            cgWindowID: 254022,
            groupID: "tabgrp-30201-s1"
        )
        let bgHigh = WindowRecord(
            id: WindowID(rawValue: "cgw-253982"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "阿方索的",
            bounds: frame,
            status: .minimized,
            cgWindowID: 253982,
            groupID: "tabgrp-30201-s1"
        )

        let items = StripItem.openWindows(from: retainedSnapshot(bgLow, visible, bgHigh))

        XCTAssertEqual(items.count, 1)
        let chip = items[0]
        XCTAssertEqual(chip.id, "tabgrp-30201-s1")
        XCTAssertEqual(chip.title, "发生的")
        XCTAssertEqual(chip.actionWindowID, "cgw-254022")
    }

    func testStripItemsDoNotMergeWhenFrameDiffers() {
        let a = WindowRecord(
            id: WindowID(rawValue: "cgw-1"),
            appID: AppID(rawValue: "com.google.Chrome"),
            pid: 64774,
            bundleIdentifier: "com.google.Chrome",
            title: "A",
            bounds: CGRect(x: 0, y: 33, width: 1512, height: 862),
            status: .inactive,
            cgWindowID: 1
        )
        let b = WindowRecord(
            id: WindowID(rawValue: "cgw-2"),
            appID: AppID(rawValue: "com.google.Chrome"),
            pid: 64774,
            bundleIdentifier: "com.google.Chrome",
            title: "B",
            bounds: CGRect(x: 0, y: 33, width: 1512, height: 887),
            status: .inactive,
            cgWindowID: 2
        )

        let items = StripItem.openWindows(from: retainedSnapshot(a, b))

        XCTAssertEqual(items.count, 2)
    }

    func testStripItemsDoNotMergeAcrossDifferentApps() {
        let frame = CGRect(x: 0, y: 32, width: 2560, height: 1410)
        let ai = WindowRecord(
            id: WindowID(rawValue: "cgw-10"),
            appID: AppID(rawValue: "com.adobe.illustrator"),
            pid: 65589,
            bundleIdentifier: "com.adobe.illustrator",
            title: "AI",
            bounds: frame,
            status: .inactive,
            cgWindowID: 10
        )
        let ps = WindowRecord(
            id: WindowID(rawValue: "cgw-11"),
            appID: AppID(rawValue: "com.adobe.Photoshop"),
            pid: 55311,
            bundleIdentifier: "com.adobe.Photoshop",
            title: "PS",
            bounds: frame,
            status: .inactive,
            cgWindowID: 11
        )

        let items = StripItem.openWindows(from: retainedSnapshot(ai, ps))

        XCTAssertEqual(items.count, 2)
    }

    func testOptimisticActiveSupersededByActiveSibling() {
        let w1 = WindowID(rawValue: "cg-sibling-1")
        let w2 = WindowID(rawValue: "cg-sibling-2")

        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }

        let now = Date()
        func superseded(predicted: WindowStatus, snapshot: DockSnapshot,
                        optimisticStates: [String: OptimisticWindowState] = [:]) -> Bool {
            OptimisticWindowState.supersededByActiveSibling(
                windowID: w1.rawValue,
                state: OptimisticWindowState(status: predicted, createdAt: now),
                now: now, optimisticStates: optimisticStates,
                snapshot: snapshot, handoffGraceEnabled: true
            )
        }

        XCTAssertTrue(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)])
        ))
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 2, status: .active)])
        ))
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)])
        ))
        XCTAssertFalse(superseded(
            predicted: .minimized,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)])
        ))
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active)])
        ))
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)]),
            optimisticStates: [w2.rawValue: OptimisticWindowState(status: .minimized, createdAt: now)]
        ))
        XCTAssertTrue(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)]),
            optimisticStates: [w2.rawValue: OptimisticWindowState(status: .active, createdAt: now)]
        ))
    }

    func testRestoreOriginOptimisticActiveSurvivesTransientSiblingActive() {
        let w1 = WindowID(rawValue: "cg-restore-1")
        let w2 = WindowID(rawValue: "cg-restore-2")
        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }
        let now = Date()
        let handoffSnapshot = makeSnapshot([
            record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active),
        ])
        let restoreOrigin = OptimisticWindowState(status: .active, createdAt: now, focusHandoffGrace: true)

        XCTAssertFalse(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue,
            state: OptimisticWindowState(status: .active, createdAt: now),
            now: now, optimisticStates: [:],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin,
            now: now.addingTimeInterval(OptimisticWindowState.handoffSupersessionGrace + 0.1),
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [
                w1.rawValue: restoreOrigin,
                w2.rawValue: OptimisticWindowState(status: .active, createdAt: now),
            ],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: handoffSnapshot, handoffGraceEnabled: false
        ))
        XCTAssertFalse(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: makeSnapshot([
                record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive),
            ]),
            handoffGraceEnabled: true
        ))
    }

    func testSystemPredictionFalsifiedOnlyClearsSystemPredictions() {
        let now = Date()
        let prediction = OptimisticWindowState(
            status: .active, createdAt: now, focusHandoffGrace: true, systemPredicted: true
        )
        let userRestore = OptimisticWindowState(status: .active, createdAt: now, focusHandoffGrace: true)

        XCTAssertTrue(OptimisticWindowState.systemPredictionFalsified(state: prediction, actual: .minimized))
        XCTAssertTrue(OptimisticWindowState.systemPredictionFalsified(state: prediction, actual: .hidden))
        XCTAssertFalse(OptimisticWindowState.systemPredictionFalsified(state: prediction, actual: .inactive))
        XCTAssertFalse(OptimisticWindowState.systemPredictionFalsified(state: userRestore, actual: .minimized))
        XCTAssertFalse(OptimisticWindowState.systemPredictionFalsified(
            state: OptimisticWindowState(status: .minimized, createdAt: now, systemPredicted: true),
            actual: .inactive
        ))
    }

    func testSiblingActivationInFlightDowngradesMinimizeToActivate() {
        let w1 = WindowID(rawValue: "cg-inflight-1")
        let w2 = WindowID(rawValue: "cg-inflight-2")
        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }
        let planner = LifecycleActionPlanner(isAppFrontmost: { _ in true })
        let optimisticW2Active = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: Date())]

        XCTAssertTrue(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue, optimisticStates: optimisticW2Active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 1, status: .inactive)])
        ))
        XCTAssertFalse(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue, optimisticStates: optimisticW2Active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)])
        ))
        XCTAssertFalse(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue, optimisticStates: optimisticW2Active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 2, status: .inactive)])
        ))
        XCTAssertFalse(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue,
            optimisticStates: ["cg-inflight-1": OptimisticWindowState(status: .active, createdAt: Date())],
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active)])
        ))
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: optimisticW2Active
            ).kind,
            .activateWindow
        )
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 1, status: .inactive)])
            ).kind,
            .minimizeWindow
        )
        let base = Date()
        var both = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: base)]
        both["cg-inflight-1"] = OptimisticWindowState(status: .active, createdAt: base.addingTimeInterval(-1.0))
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: both
            ).kind,
            .activateWindow
        )
        var ownNewer = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: base)]
        ownNewer["cg-inflight-1"] = OptimisticWindowState(status: .active, createdAt: base.addingTimeInterval(1.0))
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: ownNewer
            ).kind,
            .minimizeWindow
        )
        var tied = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: base)]
        tied["cg-inflight-1"] = OptimisticWindowState(status: .active, createdAt: base)
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: tied
            ).kind,
            .activateWindow
        )
    }

    func testMinimizedRestorePreActivation() {
        let t1 = WindowID(rawValue: "cg-restore-1")
        let t2 = WindowID(rawValue: "cg-restore-2")
        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }
        let target = record(t1, pid: 1, status: .minimized)

        XCTAssertTrue(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target]), target: target))
        XCTAssertTrue(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .minimized)]), target: target))
        XCTAssertFalse(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .inactive)]), target: target))
        XCTAssertFalse(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .active)]), target: target))
        XCTAssertFalse(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .hidden)]), target: target))
        XCTAssertTrue(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 2, status: .active)]), target: target))
    }

    private func snapshot(windowID: WindowID, status: WindowStatus) -> DockSnapshot {
        DockSnapshot(
            windows: [
                windowID: WindowRecord(
                    id: windowID,
                    appID: AppID(rawValue: "test-app"),
                    pid: 1,
                    bundleIdentifier: nil,
                    title: "Test",
                    bounds: nil,
                    status: status
                )
            ],
            orderedWindowIDs: [windowID]
        )
    }

    private func snapshot(windowCount: Int) -> DockSnapshot {
        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []

        for index in 0..<windowCount {
            let windowID = WindowID(rawValue: "cg-baseline-\(index)")
            orderedWindowIDs.append(windowID)
            windows[windowID] = WindowRecord(
                id: windowID,
                appID: AppID(rawValue: "com.example.baseline"),
                pid: Int32(1000 + index),
                bundleIdentifier: "com.example.baseline",
                title: "Baseline \(index)",
                bounds: CGRect(
                    x: CGFloat(index * 20),
                    y: CGFloat(index * 20),
                    width: 500,
                    height: 400
                ),
                status: .inactive
            )
        }

        return DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
    }

    private func retainedSnapshot(_ records: WindowRecord...) -> DockSnapshot {
        DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id)
        )
    }

    private func windowRecord(
        id: WindowID,
        pid: Int32,
        bundleIdentifier: String,
        title: String,
        bounds: CGRect,
        status: WindowStatus
    ) -> WindowRecord {
        WindowRecord(
            id: id,
            appID: AppID(rawValue: bundleIdentifier),
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            title: title,
            bounds: bounds,
            status: status
        )
    }

    private func observation(
        timestamp: Date = Date(),
        kind: SystemObservation.ObservationKind = .appeared,
        source: SystemObservation.ObservationSource,
        pid: Int32,
        bundleIdentifier: String? = "com.example.app",
        cgWindowID: UInt32? = nil,
        title: String?,
        appName: String? = "Example",
        bounds: CGRect?,
        isMinimized: Bool = false,
        isFocusedWindow: Bool = false
    ) -> SystemObservation {
        SystemObservation(
            timestamp: timestamp,
            kind: kind,
            source: source,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            cgWindowID: cgWindowID,
            title: title,
            appName: appName,
            bounds: bounds,
            isMinimized: isMinimized,
            isFocusedWindow: isFocusedWindow
        )
    }

    private func candidate(
        bundleIdentifier: String? = "com.example.app",
        appName: String = "Example",
        title: String?,
        subrole: String? = nil,
        bounds: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300),
        alpha: Double? = 1,
        activationPolicy: NSApplication.ActivationPolicy,
        executablePath: String? = "/Applications/Example.app/Contents/MacOS/Example"
    ) -> DockWindowEligibilityPolicy.Candidate {
        DockWindowEligibilityPolicy.Candidate(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            subrole: subrole,
            bounds: bounds,
            alpha: alpha,
            activationPolicy: activationPolicy,
            executablePath: executablePath
        )
    }

    func testReconcileKeepsManualOrderOnUnchangedRefresh() {
        let manual = ["C", "A", "B"]
        let result = StripOrdering.reconcile(remembered: manual, current: ["A", "B", "C"])
        XCTAssertEqual(result, ["C", "A", "B"])
    }

    func testReconcileAppendsNewcomersAtTail() {
        let result = StripOrdering.reconcile(remembered: ["C", "A", "B"], current: ["A", "B", "C", "D"])
        XCTAssertEqual(result, ["C", "A", "B", "D"])
    }

    func testReconcileAppendsMultipleNewcomersInCurrentOrder() {
        let result = StripOrdering.reconcile(remembered: ["B", "A"], current: ["A", "B", "D", "C"])
        XCTAssertEqual(result, ["B", "A", "D", "C"])
    }

    func testReconcileInsertsNewWindowNextToSameAppSibling() {
        let appKeyOf = ["A": "a", "G": "ghostty", "B": "b", "G2": "ghostty"]
        let result = StripOrdering.reconcile(
            remembered: ["A", "G", "B"],
            current: ["A", "G", "G2", "B"],
            appKeyOf: appKeyOf
        )
        XCTAssertEqual(result, ["A", "G", "G2", "B"])
    }

    func testReconcileAppendsBrandNewAppAtTail() {
        let appKeyOf = ["A": "a", "G": "ghostty", "B": "b", "X": "x"]
        let result = StripOrdering.reconcile(
            remembered: ["G", "A", "B"],
            current: ["A", "G", "B", "X"],
            appKeyOf: appKeyOf
        )
        XCTAssertEqual(result, ["G", "A", "B", "X"])
    }

    func testReconcileDropsClosedAndPreservesRest() {
        let result = StripOrdering.reconcile(remembered: ["C", "A", "B", "D"], current: ["B", "C", "D"])
        XCTAssertEqual(result, ["C", "B", "D"])
    }

    func testReconcileDoesNotRegroupScatteredSameAppChips() {
        let scattered = ["A1", "B", "A2"]
        let result = StripOrdering.reconcile(remembered: scattered, current: ["A1", "A2", "B"])
        XCTAssertEqual(result, ["A1", "B", "A2"])
    }

    func testReconcileHandlesSimultaneousCloseAndOpen() {
        let result = StripOrdering.reconcile(remembered: ["C", "A", "B"], current: ["C", "B", "E"])
        XCTAssertEqual(result, ["C", "B", "E"])
    }

    func testReconcileWithEmptyMemoryAdoptsCurrentOrder() {
        let result = StripOrdering.reconcile(remembered: [], current: ["A", "B", "C"])
        XCTAssertEqual(result, ["A", "B", "C"])
    }

    func testReorderingDropsAfterTarget() {
        let result = StripOrdering.reordering(["A", "B", "C"], move: "A", relativeTo: "C", after: true)
        XCTAssertEqual(result, ["B", "C", "A"])
    }

    func testReorderingDropsBeforeTarget() {
        let result = StripOrdering.reordering(["A", "B", "C"], move: "A", relativeTo: "C", after: false)
        XCTAssertEqual(result, ["B", "A", "C"])
    }

    func testReorderingMovesLeftBeforeTarget() {
        let result = StripOrdering.reordering(["A", "B", "C"], move: "C", relativeTo: "A", after: false)
        XCTAssertEqual(result, ["C", "A", "B"])
    }

    func testReorderingGuardsSelfAndMissing() {
        XCTAssertEqual(StripOrdering.reordering(["A", "B"], move: "A", relativeTo: "A", after: true), ["A", "B"])
        XCTAssertEqual(StripOrdering.reordering(["A", "B"], move: "Z", relativeTo: "A", after: true), ["A", "B"])
        XCTAssertEqual(StripOrdering.reordering(["A", "B"], move: "A", relativeTo: "Z", after: false), ["A", "B"])
    }

    func testAppOnlyEntriesCannotExecuteWindowActions() {
        let id = WindowID(rawValue: "app-com.example.no-windows")
        let state = snapshot(windowID: id, status: .inactive)
        let executor = PlatformActionExecutor()
        for kind in [PlatformActionRequest.ActionKind.activateWindow, .minimizeWindow, .closeWindow] {
            XCTAssertFalse(executor.execute(
                PlatformActionRequest(kind: kind, windowID: id),
                snapshot: state, forcedMinimizedPrior: false, cancellation: OperationCancellation(), onHandoffActivePrediction: nil))
        }
    }
}
