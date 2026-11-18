import ApplicationServices
import Combine
import XCTest

final class ExternalWindowGeometryTests: XCTestCase {
    func testInventoryRejectsInvalidKnownGeometryBeforeTabFolding() {
        let app = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "audit.example.geometry", appName: "Geometry",
            activationPolicy: .regular, executablePath: "/Applications/Geometry.app/Contents/MacOS/Geometry"
        )
        let frames = [
            CGRect(x: 1e30, y: 100, width: 800, height: 600),
            CGRect(x: -1e30, y: 100, width: 800, height: 600),
            CGRect(x: CGFloat.nan, y: 100, width: 800, height: 600),
            CGRect(x: 100, y: CGFloat.infinity, width: 800, height: 600),
            CGRect(x: 100, y: 100, width: 1e30, height: 600),
            CGRect(x: 100, y: 100, width: 800, height: -CGFloat.infinity),
            CGRect(x: 100, y: 100, width: 0, height: 600),
            CGRect(x: 100, y: 100, width: -800, height: 600),
            CGRect(x: 100, y: 100, width: 800, height: -600),
            CGRect(x: CGFloat(Int.max), y: 100, width: 800, height: 600)
        ]
        for frame in frames {
            XCTAssertFalse(AppTrackerWindowEligibility().isEligible(
                title: "Window", role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String, bounds: frame,
                alpha: 1, isMinimized: true, isBelowNormalLayer: false, application: app
            ), "Invalid external frame was admitted: \(frame)")
        }
    }

    func testNegativeMonitorCoordinatesAndUnknownFrameRemainEligible() {
        let app = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "audit.example.geometry", appName: "Geometry",
            activationPolicy: .regular, executablePath: "/Applications/Geometry.app/Contents/MacOS/Geometry"
        )
        for frame: CGRect? in [CGRect(x: -2560.5, y: -120.25, width: 800.5, height: 600), nil] {
            XCTAssertTrue(AppTrackerWindowEligibility().isEligible(
                title: "Window", role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String, bounds: frame,
                alpha: 1, isMinimized: true, isBelowNormalLayer: false, application: app
            ))
        }
    }
}

final class AXWindowReaderResultTests: XCTestCase {
    func testSuccessfulTitleReadPreservesOriginalNonemptyText() {
        let original = "  Window  "
        XCTAssertEqual(AXWindowTitleRead.classify(result: .success, value: original as CFString),
                       .value(original))
    }

    func testOrdinaryEditorWindowIsNotFilteredByItsDocumentTitle() {
        let app = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "review.example.editor", appName: "Review Editor",
            activationPolicy: .regular,
            executablePath: "/Applications/ReviewEditor.app/Contents/MacOS/ReviewEditor"
        )
        let policy = AppTrackerWindowEligibility()
        func eligible(_ title: String) -> Bool {
            policy.isEligible(title: title, role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 1,
                isMinimized: false, isBelowNormalLayer: false, application: app,
                isModal: false, isTopLevel: true, isNativeRoot: true, isFocusedWindow: true)
        }
        XCTAssertTrue(eligible("Ordinary document"))
        XCTAssertTrue(eligible("Notification Center"))
    }

    func testRollbackAcceptsOnlyFramesOwnedByThePartialWrite() {
        let original = CGRect(x: 100, y: 100, width: 900, height: 700)
        let partial = CGRect(x: 100, y: 100, width: 900, height: 668)
        let target = CGRect(x: 100, y: 132, width: 900, height: 668)
        XCTAssertTrue(AXWindowFrameRollbackPolicy.accepts(partial, attemptedFrames: [partial, target], tolerance: 1))
        XCTAssertTrue(AXWindowFrameRollbackPolicy.accepts(target, attemptedFrames: [partial, target], tolerance: 1))
        XCTAssertFalse(AXWindowFrameRollbackPolicy.accepts(original, attemptedFrames: [partial, target], tolerance: 1))
        XCTAssertFalse(AXWindowFrameRollbackPolicy.accepts(CGRect(x: 500, y: 100, width: 900, height: 668),
            attemptedFrames: [partial, target], tolerance: 1))
        XCTAssertFalse(AXWindowFrameRollbackPolicy.accepts(partial, attemptedFrames: [], tolerance: 1))
    }

    func testAXWindowArraysValidateEveryElementType() throws {
        let element = AXUIElementCreateApplication(-42)
        XCTAssertEqual(try XCTUnwrap(AXWindowReader.validatedElements([element] as CFArray)).count, 1)
        XCTAssertNil(AXWindowReader.validatedElements([element, "wrong" as CFString] as CFArray))
        XCTAssertNil(AXWindowReader.validatedElements("wrong" as CFString))
        let cancellation = OperationCancellation()
        cancellation.cancel()
        XCTAssertNil(AXWindowReader.validatedElements([element] as CFArray,
            budget: OperationReadBudget(maximumDuration: 1, cancellation: cancellation)))
    }

    func testWindowIDsRejectTruncationFractionsAndBooleans() {
        for number in [NSNumber(value: -1), NSNumber(value: UInt64(UInt32.max) + 1),
                       NSNumber(value: 42.5), NSNumber(value: true), NSNumber(value: Double.nan), NSNumber(value: Double.infinity)] {
            XCTAssertNil(AXWindowIDBridge.cgWindowID(from: number), "Invalid ID admitted: \(number)")
        }
        XCTAssertEqual(AXWindowIDBridge.cgWindowID(from: NSNumber(value: UInt32.max)), UInt32.max)
        XCTAssertEqual(AXWindowIDBridge.cgWindowID(from: " 42 " as CFString), 42)
    }

    func testSuccessPreservesOriginalWindowArray() {
        let snapshot = AXWindowSnapshot(
            pid: 42,
            cgWindowID: 123,
            titleRead: .value("test"),
            bounds: nil,
            role: nil,
            subrole: nil,
            isMinimized: false,
            isFocusedWindow: false,
            element: AXUIElementCreateApplication(42)
        )

        let windows = AXWindowReadResult.success([snapshot]).windowsOrEmpty

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].pid, snapshot.pid)
        XCTAssertEqual(windows[0].cgWindowID, snapshot.cgWindowID)
        XCTAssertEqual(windows[0].title, "test")
    }

    func testUnreadStillMapsToEmptyArrayAndKeepsError() {
        let result = AXWindowReadResult.unread(.cannotComplete)

        XCTAssertTrue(result.windowsOrEmpty.isEmpty)
        guard case .unread(let error) = result else {
            return XCTFail("expected unread")
        }
        XCTAssertEqual(error, .cannotComplete)
    }

    func testTitleReadClassifiesNonEmptyAndKnownEmptyValues() {
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .success, value: "  Window  " as CFString),
            .value("  Window  ")
        )
        XCTAssertEqual(AXWindowTitleRead.classify(result: .success, value: "" as CFString), .empty)
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .success, value: " \n\t " as CFString),
            .empty
        )
        XCTAssertEqual(AXWindowTitleRead.classify(result: .noValue, value: nil), .empty)
        XCTAssertEqual(AXWindowTitleRead.classify(result: .attributeUnsupported, value: nil), .empty)
    }

    func testTitleReadKeepsFailuresDistinctFromEmpty() {
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .cannotComplete, value: nil),
            .unread(.cannotComplete)
        )
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .success, value: NSNumber(value: 7)),
            .unread(.failure)
        )
    }
}

final class PublishedWindowInventoryTests: XCTestCase {
    func testInventoryReadsOrdinaryWindowAttributesInOneBatch() throws {
        let access = BatchedInventoryFixture()
        let result = AXWindowReader(accessibility: access).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        let window = try XCTUnwrap(result.windowsOrEmpty.first)
        XCTAssertEqual(window.cgWindowID, 1001)
        XCTAssertEqual(window.titleRead, .value("Batched title"))
        XCTAssertEqual(window.bounds, CGRect(x: 30, y: 70, width: 800, height: 600))
        XCTAssertEqual(window.role, kAXWindowRole as String)
        XCTAssertEqual(window.subrole, kAXStandardWindowSubrole as String)
        XCTAssertEqual(window.isMinimizedRead, false)
        XCTAssertEqual(access.batches, 1)
        XCTAssertEqual(access.scalarWindowAttributes, [])
    }

    func testBatchTimeoutDoesNotRepeatTheWindowReadsIndividually() {
        let access = BatchedInventoryFixture(result: .cannotComplete)
        let result = AXWindowReader(accessibility: access).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        guard case .unread(.cannotComplete) = result else {
            return XCTFail("Expected the inventory to retain the batch timeout")
        }
        XCTAssertEqual(access.batches, 1)
        XCTAssertEqual(access.scalarWindowAttributes, [])
    }

    func testUnsupportedBatchReadsTheSameWindowThroughScalarFallback() throws {
        let access = BatchedInventoryFixture(result: .notImplemented)
        let result = AXWindowReader(accessibility: access).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        XCTAssertEqual(try XCTUnwrap(result.windowsOrEmpty.first).cgWindowID, 1001)
        XCTAssertEqual(access.batches, 1)
        XCTAssertEqual(access.scalarWindowAttributes.count, 6)
    }

    func testBatchPreservesPerAttributeErrorsAndReadsOnlyAmbiguousNullsAgain() throws {
        let access = BatchedInventoryFixture(titleError: .cannotComplete, nullRole: true)
        let result = AXWindowReader(accessibility: access).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        let window = try XCTUnwrap(result.windowsOrEmpty.first)
        XCTAssertEqual(window.titleRead, .unread(.cannotComplete))
        XCTAssertEqual(window.role, kAXWindowRole as String)
        XCTAssertEqual(access.batches, 1)
        XCTAssertEqual(access.scalarWindowAttributes, [kAXRoleAttribute as String])
    }

    func testFocusedWindowSurvivesAnEmptyPublishedList() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.enumeratedWindows[-41000] = [] }
        let result = AXWindowReader(accessibility: desktop).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.windowsOrEmpty.compactMap(\.cgWindowID), [1001])
        XCTAssertEqual(result.windowsOrEmpty.map(\.isFocusedWindow), [true])
    }

    func testMainWindowSurvivesAnEmptyListWithoutFocus() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.enumeratedWindows[-41000] = []
            $0.focused = nil
            $0.publishedMainWindows[-41000] = 1002
        }
        let result = AXWindowReader(accessibility: desktop).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        XCTAssertEqual(result.windowsOrEmpty.compactMap(\.cgWindowID), [1002])
        XCTAssertEqual(result.windowsOrEmpty.map(\.isFocusedWindow), [false])
    }

    func testListFocusAndMainAreMergedWithoutDuplicateSeats() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.enumeratedWindows[-41000] = [1002]
            $0.publishedMainWindows[-41000] = 1002
        }
        let result = AXWindowReader(accessibility: desktop).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        XCTAssertEqual(result.windowsOrEmpty.compactMap(\.cgWindowID), [1002, 1001])
    }

    func testAFormerFocusedWindowCannotBeRelabeledWithAnotherOwner() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.enumeratedWindows[-41000] = []
            $0.publishedFocusedWindows[-41000] = 2001
            $0.publishedMainWindows[-41000] = 1002
        }
        let result = AXWindowReader(accessibility: desktop).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        XCTAssertEqual(result.windowsOrEmpty.compactMap(\.cgWindowID), [1002])
        XCTAssertEqual(result.windowsOrEmpty.map(\.isFocusedWindow), [false])
    }

    func testUnreadListDoesNotBecomeASuccessfulPartialInventory() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.unreadInventories.insert(-41000) }
        guard case .unread(.cannotComplete) = AXWindowReader(accessibility: desktop)
            .inventoryWindows(forPID: -41000, messagingTimeout: 0.1) else {
            return XCTFail("A focused window must not turn an unanswered inventory into confirmed absence of its siblings")
        }
    }

    func testExactCaptureSkipsForeignFallbackAndUsesTheOwnedWindow() throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.publishedFocusedWindows[-41000] = 2001
            $0.unreadNativeWindowIDs = [1002, 2001]
            $0.windowIDAttributes = [1002: 1002, 2001: 1002]
        }
        let handle = try XCTUnwrap(AXWindowReader(accessibility: desktop)
            .captureHandle(forPID: -41000, cgWindowID: 1002))

        XCTAssertEqual(desktop.number(handle.element), 1002)
    }
}

private final class BatchedInventoryFixture: AccessibilityOperations, @unchecked Sendable {
    let desktop = BehaviorDesktop()
    let result: AXError
    let titleError: AXError?
    let nullRole: Bool
    private let windowAttributes = Set([
        kAXMinimizedAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXRoleAttribute, kAXSubroleAttribute,
    ].map { $0 as String })
    private(set) var batches = 0
    private(set) var scalarWindowAttributes: [String] = []

    init(result: AXError = .success, titleError: AXError? = nil, nullRole: Bool = false) {
        self.result = result
        self.titleError = titleError
        self.nullRole = nullRole
        desktop.state.withLock { $0.enumeratedWindows[-41000] = [1001] }
    }

    func isTrusted() -> Bool { desktop.isTrusted() }
    func application(_ pid: pid_t) -> AXUIElement { desktop.application(pid) }
    func windowID(_ element: AXUIElement) -> CGWindowID? { desktop.windowID(element) }
    func pid(_ element: AXUIElement) -> pid_t? { desktop.pid(element) }
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError { desktop.setTimeout(element, timeout) }
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        desktop.set(element, attribute, value)
    }
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError { desktop.perform(element, action) }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) {
        desktop.isSettable(element, attribute)
    }

    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        if windowAttributes.contains(attribute as String) { scalarWindowAttributes.append(attribute as String) }
        return desktop.copy(element, attribute)
    }

    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?) {
        batches += 1
        guard result == .success else { return (result, nil) }
        XCTAssertEqual(Set(attributes), windowAttributes)
        return (.success, attributes.map { attribute in
            switch attribute {
            case kAXTitleAttribute as String:
                if var titleError {
                    return AXValueCreate(.axError, &titleError)!
                }
                return "Batched title" as CFString
            case kAXPositionAttribute as String:
                var point = CGPoint(x: 30, y: 70)
                return AXValueCreate(.cgPoint, &point)!
            case kAXSizeAttribute as String:
                var size = CGSize(width: 800, height: 600)
                return AXValueCreate(.cgSize, &size)!
            case kAXRoleAttribute as String where nullRole:
                return kCFNull
            default:
                return desktop.copy(element, attribute as CFString).1 ?? kCFNull
            }
        })
    }
}

final class ActionExecutionSwitchesTests: XCTestCase {
    func testFastHandleMetadataPreservesSnapshotTarget() {
        let bounds = CGRect(x: 10, y: 20, width: 900, height: 700)
        let rawHandle = AXWindowHandle(
            pid: 42,
            title: nil,
            bounds: nil,
            element: AXUIElementCreateApplication(42)
        )
        let handle = AccessibilityWindowActionExecutor.fastHandle(
            from: rawHandle,
            target: .init(pid: 42, title: "Project Window", bounds: bounds)
        )

        XCTAssertEqual(handle.pid, 42)
        XCTAssertEqual(handle.title, "Project Window")
        XCTAssertEqual(handle.bounds, bounds)
    }

    func testTargetMetadataSelectsOneWindowWhileMissingMetadataStaysAmbiguous() {
        let targetBounds = CGRect(x: 10, y: 20, width: 900, height: 700)
        let candidates = [
            AXWindowMatchPolicy.Candidate(
                title: "Project Window",
                bounds: CGRect(x: 1000, y: 20, width: 900, height: 700)
            ),
            AXWindowMatchPolicy.Candidate(title: "Project Window", bounds: targetBounds),
        ]

        XCTAssertEqual(AXWindowMatchPolicy.uniqueBestMatchIndex(
            targetTitle: "Project Window",
            targetBounds: targetBounds,
            candidates: candidates
        ), 1)
        XCTAssertNil(AXWindowMatchPolicy.uniqueBestMatchIndex(
            targetTitle: nil,
            targetBounds: nil,
            candidates: candidates
        ))
    }

    func testDefaultsUseFastHandleAndDisableDiagnosticsAndMinimizeFallback() {
        let switches = ActionExecutionSwitches(environment: [:])

        XCTAssertTrue(switches.fastWindowHandleEnabled)
        XCTAssertFalse(switches.chipProbeEnabled)
    }

    func testMissingExactWindowNeverFallsBackToAnIdenticalSurvivor() {
        let bounds = CGRect(x: 40, y: 40, width: 640, height: 480)
        let remaining = [AXWindowMatchPolicy.Candidate(title: "Untitled", bounds: bounds, cgWindowID: 202)]
        for justUnhid in [false, true] {
            var receivedID: CGWindowID?
            let selected: Int? = WindowHandleCapturePlan.capture(
                cachedEnabled: true, fastEnabled: true, cgWindowID: 101, justUnhid: justUnhid,
                cached: { _ in nil }, fast: { _ in nil }, fallback: { expectedID in
                    receivedID = expectedID
                    return AXWindowMatchPolicy.uniqueBestMatchIndex(targetTitle: "Untitled", targetBounds: bounds,
                        candidates: remaining, expectedCGWindowID: expectedID)
                })
            XCTAssertEqual(receivedID, 101)
            XCTAssertNil(selected)
        }
    }

    func testExactWindowSurvivesRenamingAndMovingWithoutMatchingASibling() {
        let candidates = [
            AXWindowMatchPolicy.Candidate(title: "Old title", bounds: .zero, cgWindowID: 202),
            AXWindowMatchPolicy.Candidate(title: "New title", bounds: CGRect(x: 900, y: 80, width: 400, height: 300), cgWindowID: 101),
        ]
        XCTAssertEqual(AXWindowMatchPolicy.uniqueBestMatchIndex(targetTitle: "Old title", targetBounds: .zero,
            candidates: candidates, expectedCGWindowID: 101), 1)
    }

    func testExactWindowRejectsUnreadZeroAndDuplicateIdentities() {
        for candidates in [
            [AXWindowMatchPolicy.Candidate(title: "Untitled", bounds: .zero)],
            [AXWindowMatchPolicy.Candidate(title: "Untitled", bounds: .zero, cgWindowID: 101),
             AXWindowMatchPolicy.Candidate(title: "Untitled", bounds: .zero, cgWindowID: 101)],
        ] {
            XCTAssertNil(AXWindowMatchPolicy.uniqueBestMatchIndex(targetTitle: "Untitled", targetBounds: .zero,
                candidates: candidates, expectedCGWindowID: 101))
        }
        XCTAssertNil(AXWindowMatchPolicy.uniqueBestMatchIndex(targetTitle: "Untitled", targetBounds: .zero,
            candidates: [.init(title: "Untitled", bounds: .zero, cgWindowID: 0)], expectedCGWindowID: 0))
    }

    func testKnownWindowNeverActivatesAnotherWindowThroughAppRecovery() {
        for kind in [PlatformActionRequest.ActionKind.activateWindow, .minimizeWindow, .closeWindow] {
            XCTAssertFalse(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
                requestKind: kind, isFinderWindow: false, knownMinimized: false, expectedCGWindowID: 101))
        }
    }

    func testCompatibilityKillSwitchesAreDirectional() {
        let switches = ActionExecutionSwitches(environment: [
            "DOCK_FAST_WINDOW_HANDLE": "0",
            "DOCK_CHIP_PROBE": "1",
        ])

        XCTAssertFalse(switches.fastWindowHandleEnabled)
        XCTAssertTrue(switches.chipProbeEnabled)
    }

    func testFastHandleHitSkipsFallback() {
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: false,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in nil },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { _ in fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fast")
        XCTAssertEqual(fastCalls, 1)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testFastHandleMissFallsBackExactlyOnce() {
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: false,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in nil },
            fast: { _ in fastCalls += 1; return nil },
            fallback: { _ in fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(fastCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCachedHandleHitSkipsBothSlowerTiers() {
        var cachedCalls = 0
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { _ in fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "cached")
        XCTAssertEqual(cachedCalls, 1)
        XCTAssertEqual(fastCalls, 0)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testCachedHandleMissFallsThroughToFastThenFallback() {
        var cachedCalls = 0
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return nil },
            fast: { _ in fastCalls += 1; return nil },
            fallback: { _ in fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(cachedCalls, 1)
        XCTAssertEqual(fastCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testJustUnhidSkipsCachedAndFastTiers() {
        var cachedCalls = 0
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: true,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { _ in fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(cachedCalls, 0)
        XCTAssertEqual(fastCalls, 0)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCacheDisabledRestoresPreviousTwoTierBehaviour() {
        var cachedCalls = 0
        var fastCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: false,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { _ in "fallback" }
        )

        XCTAssertEqual(result, "fast")
        XCTAssertEqual(cachedCalls, 0)
        XCTAssertEqual(fastCalls, 1)
    }

    func testNoCGWindowIDGoesStraightToFallback() {
        var cachedCalls = 0
        var fastCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: nil,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { _ in "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(cachedCalls, 0)
        XCTAssertEqual(fastCalls, 0)
    }

    func testOnlyUnminimizedNonFinderActivationMayUseAppRecovery() {
        for kind in [PlatformActionRequest.ActionKind.activateWindow, .minimizeWindow, .closeWindow] {
            for finder in [false, true] {
                for minimized in [false, true] {
                    XCTAssertEqual(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
                        requestKind: kind, isFinderWindow: finder, knownMinimized: minimized),
                        kind == .activateWindow && !finder && !minimized)
                }
            }
        }
    }

}

@MainActor
final class AppTrackerReadSemanticsTests: XCTestCase {
    private let pid: pid_t = 4242
    private let cgWindowID: CGWindowID = 77

    func testUnreadRoundPreservesSeatAbsenceAndShadowState() throws {
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerUnreadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog)
        let absence = Date(timeIntervalSince1970: 10)
        let episode = UUID()
        tracker.installFixtureForTesting(makeApp(
            isMinimized: true,
            minAbsentSince: absence,
            episodeID: episode,
            shadowIDs: [88, 89]
        ))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: Self.emptyCGSnapshot(),
            now: Date(timeIntervalSince1970: 100),
            eligible: [],
            readOutcome: .unread(errorCode: AXError.cannotComplete.rawValue)
        )

        XCTAssertFalse(changed)
        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID])
        XCTAssertEqual(app?.shadowTabCgIDs, [88, 89])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.minAbsentSince, absence)
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.absenceEpisodeID, episode)

        inventoryLog.flush()
        let text = try String(contentsOf: inventoryLog.currentFileURL, encoding: .utf8)
        let record = try XCTUnwrap(text.split(separator: "\n").first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["event"] as? String, "reconcileUnread")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["readMode"] as? String, "timed")
        XCTAssertEqual(payload["usedPreloadedAX"] as? Bool, true)
        XCTAssertEqual(payload["errorCode"] as? Int, Int(AXError.cannotComplete.rawValue))
    }

    func testSuccessfulEmptyRoundsKeepCGPresentSeatAndShadowPool() throws {
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerEmptyInventoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog)
        tracker.installFixtureForTesting(makeApp(shadowIDs: [88, 89]))
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID, 88, 89],
            onScreenWindowIDs: [],
            windowIDsByPID: [pid: [cgWindowID, 88, 89]],
            alphaByWindowID: [:]
        )

        for now in [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 110)] {
            _ = tracker.reconcileFixtureForTesting(
                pid: pid,
                cgSnapshot: cgSnapshot,
                now: now,
                eligible: [],
                readOutcome: .success(count: 0)
            )
        }

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.title, "Window")
        XCTAssertEqual(
            app?.windowsByID[cgWindowID]?.bounds,
            CGRect(x: 10, y: 20, width: 500, height: 400)
        )
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.isFocused, false)
        XCTAssertEqual(app?.shadowTabCgIDs, [88, 89])

        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        XCTAssertFalse(records.contains { record in
            guard record["event"] as? String == "seatReleased",
                  let payload = record["payload"] as? [String: Any] else { return false }
            return payload["reason"] as? String == "absentBeyondGrace"
        })
    }

    func testUnidentifiedSnapshotDoesNotReleaseCGPresentSeat() {
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [cgWindowID],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 100),
            eligible: [makeSnapshot(cgWindowID: nil, titleRead: .value("Unknown ID"))],
            readOutcome: .success(count: 1)
        )

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.title, "Window")
    }

    func testPartialInventoryRetainsOldSeatAndSideWindowStillClosesNormally() throws {
        let sideWindowID: CGWindowID = 88
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerPartialInventoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog)
        tracker.installFixtureForTesting(makeApp(seatToken: "existing-seat"))
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID, sideWindowID],
            onScreenWindowIDs: [cgWindowID, sideWindowID],
            windowIDsByPID: [pid: [cgWindowID, sideWindowID]],
            alphaByWindowID: [:]
        )

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 100),
            eligible: [
                makeSnapshot(cgWindowID: nil, titleRead: .value("Unknown ID")),
                makeSnapshot(
                    cgWindowID: sideWindowID,
                    titleRead: .value("Side"),
                    bounds: CGRect(x: 700, y: 20, width: 500, height: 400)
                ),
            ],
            readOutcome: .success(count: 2)
        )

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID, sideWindowID])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.token, "existing-seat")
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.title, "Window")
        XCTAssertEqual(app?.windowsByID[sideWindowID]?.title, "Side")
        XCTAssertNotEqual(app?.windowsByID[sideWindowID]?.token, "existing-seat")

        let mainOnlyCGSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [cgWindowID],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: mainOnlyCGSnapshot,
            now: Date(timeIntervalSince1970: 110),
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"))],
            readOutcome: .success(count: 1)
        )

        let finalApp = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(finalApp?.windowOrder, [cgWindowID])
        XCTAssertEqual(finalApp?.windowsByID[cgWindowID]?.token, "existing-seat")
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let sideRelease = try XCTUnwrap(records.first { record in
            guard record["event"] as? String == "seatReleased",
                  let payload = record["payload"] as? [String: Any] else { return false }
            return payload["activeCgID"] as? Int == Int(sideWindowID)
        })
        let payload = try XCTUnwrap(sideRelease["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "leftCGList")
    }

    func testRetainedSeatReappearsWithSameTokenAndHeldTitle() {
        let tracker = AppTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp())
        let element = AXUIElementCreateApplication(pid)
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [cgWindowID],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 90),
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"), element: element)],
            readOutcome: .success(count: 1)
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 100),
            eligible: [],
            readOutcome: .success(count: 0)
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 110),
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .unread(.cannotComplete), element: element)],
            readOutcome: .success(count: 1)
        )

        let seat = tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]
        XCTAssertEqual(seat?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(seat?.title, "Window")
    }

    func testCGDisappearanceReleasesSeatAsLeftCGList() throws {
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerCGCloseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog)
        tracker.installFixtureForTesting(makeApp())

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: Self.emptyCGSnapshot(),
            now: Date(timeIntervalSince1970: 100),
            eligible: [],
            readOutcome: .success(count: 0)
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [])
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let release = try XCTUnwrap(records.first { $0["event"] as? String == "seatReleased" })
        let payload = try XCTUnwrap(release["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "leftCGList")
        XCTAssertEqual(payload["seatToken"] as? String, "tabgrp-\(pid)-s1")
    }

    func testDestroyTombstoneReleasesSeatEvenWhileCGStillListsIt() async throws {
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerDestroyCloseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let reader = ControlledAppTrackerReader(
            result: .success([]),
            blocksTimedReads: false
        )
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            inventoryLog: inventoryLog,
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { cgSnapshot }
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.destroyForTesting(pid: pid, cgWindowID: cgWindowID)
        XCTAssertEqual(reader.untimedReadCount, 0)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }
        XCTAssertEqual(reader.untimedReadCount, 0)

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [])
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let release = try XCTUnwrap(records.first { $0["event"] as? String == "seatReleased" })
        let payload = try XCTUnwrap(release["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "leftCGList")
    }

    func testSameWindowUnreadTitlePreservesKnownTitleAndLogsHold() throws {
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerTitleHeldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog)
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(tracker, eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"))])
        _ = reconcile(
            tracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .unread(.cannotComplete))]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.title, "Window")
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let held = try XCTUnwrap(records.first { $0["event"] as? String == "titleHeld" })
        let payload = try XCTUnwrap(held["payload"] as? [String: Any])
        XCTAssertEqual(payload["pid"] as? Int, Int(pid))
        XCTAssertEqual(payload["seatToken"] as? String, "tabgrp-\(pid)-s1")
        XCTAssertEqual(payload["activeCgID"] as? Int, Int(cgWindowID))
        XCTAssertEqual(payload["errorCode"] as? Int, Int(AXError.cannotComplete.rawValue))
        XCTAssertNil(payload["title"])
        XCTAssertNil(payload["previousTitle"])
    }

    func testReplacementAXElementWithReusedCGIDDoesNotInheritUnreadTitle() throws {
        let tracker = AppTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp())
        _ = reconcile(tracker, eligible: [
            makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Prior AX window"))
        ])
        let replacement = makeSnapshot(cgWindowID: cgWindowID, titleRead: .unread(.cannotComplete),
                                       element: AXUIElementCreateApplication(pid + 1))
        _ = reconcile(tracker, eligible: [replacement])
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindowID])

        XCTAssertEqual(tracker.snapshot.windows.values.first?.title, "")
        let current = try XCTUnwrap(AXElementCache.shared.element(pid: pid, cgWindowID: cgWindowID))
        XCTAssertTrue(CFEqual(current, replacement.element))
    }

    func testReplacementAXElementWithReusedCGIDChangesCommandIdentityWithoutMovingItsSeat() throws {
        let tracker = AppTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp())
        let first = makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"))
        _ = reconcile(tracker, eligible: [first])
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindowID])
        let initial = tracker.snapshot
        let original = try XCTUnwrap(initial.windows.values.first)

        let replacement = makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"),
                                       element: AXUIElementCreateApplication(pid + 1))
        XCTAssertTrue(reconcile(tracker, eligible: [replacement]))
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindowID])
        let current = try XCTUnwrap(tracker.snapshot.windows[original.id])
        XCTAssertNotEqual(current.actionIdentity, original.actionIdentity)
        XCTAssertEqual(current.groupID, original.groupID)
        XCTAssertEqual(tracker.snapshot.orderedWindowIDs, initial.orderedWindowIDs)

        let sameReplacement = makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"),
                                           element: AXUIElementCreateApplication(pid + 1))
        XCTAssertFalse(reconcile(tracker, eligible: [sameReplacement]))
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindowID])
        XCTAssertEqual(tracker.snapshot.windows[original.id]?.actionIdentity, current.actionIdentity)

        let minimized = makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"),
                                     element: replacement.element, isMinimized: true)
        _ = reconcile(tracker, eligible: [minimized], onScreenCGWindowIDs: [])
        _ = reconcile(tracker, eligible: [], allCGWindowIDs: [cgWindowID], onScreenCGWindowIDs: [])
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [])
        XCTAssertEqual(tracker.snapshot.windows[original.id]?.status, .minimized)
        XCTAssertEqual(tracker.snapshot.windows[original.id]?.actionIdentity, current.actionIdentity)
    }

    func testTitleHeldIsNotLoggedWhenNoPreviousTitleIsInherited() throws {
        let logDirectory = TestFileSystem.temporaryDirectory
            .appendingPathComponent("AppTrackerTitleNotHeldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))

        let knownEmptyTracker = AppTracker(inventoryLog: inventoryLog)
        knownEmptyTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            knownEmptyTracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .empty)]
        )

        let knownValueTracker = AppTracker(inventoryLog: inventoryLog)
        knownValueTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            knownValueTracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Updated"))]
        )

        let replacementID: CGWindowID = 88
        let replacementTracker = AppTracker(inventoryLog: inventoryLog)
        replacementTracker.installFixtureForTesting(makeApp())
        _ = reconcileConfirmedTabReplacement(
            replacementTracker,
            replacementID: replacementID,
            titleRead: .unread(.cannotComplete)
        )
        XCTAssertEqual(replacementTracker.fixtureAppForTesting(pid: pid)?.windowOrder, [replacementID])
        XCTAssertEqual(replacementTracker.fixtureAppForTesting(pid: pid)?.windowsByID[replacementID]?.token, "tabgrp-\(pid)-s1")

        let newWindowID: CGWindowID = 99
        let newSeatTracker = AppTracker(inventoryLog: inventoryLog)
        newSeatTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            newSeatTracker,
            eligible: [
                makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window")),
                makeSnapshot(
                    cgWindowID: newWindowID,
                    titleRead: .unread(.cannotComplete),
                    bounds: CGRect(x: 700, y: 20, width: 500, height: 400)
                ),
            ],
            allCGWindowIDs: [cgWindowID, newWindowID]
        )

        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        XCTAssertFalse(records.contains { $0["event"] as? String == "titleHeld" })
    }

    func testSameWindowKnownEmptyTitleClearsKnownTitle() {
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(tracker, eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .empty)])

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.title, "")
    }

    func testSameWindowKnownTitleUpdatesKnownTitle() {
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(
            tracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Updated"))]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.title, "Updated")
    }

    func testTabReplacementDoesNotInheritUnreadTitle() {
        let replacementID: CGWindowID = 88
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())

        _ = reconcileConfirmedTabReplacement(
            tracker,
            replacementID: replacementID,
            titleRead: .unread(.cannotComplete)
        )

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [replacementID])
        XCTAssertEqual(app?.windowsByID[replacementID]?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(app?.windowsByID[replacementID]?.title, "")
    }

    func testTearOutReplacementDoesNotInheritUnreadTitle() {
        let replacementID: CGWindowID = 88
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())
        let originalBounds = CGRect(x: 10, y: 20, width: 500, height: 400)
        let movedBounds = CGRect(x: 700, y: 20, width: 500, height: 400)

        _ = reconcile(
            tracker,
            eligible: [
                makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Moved"), bounds: movedBounds),
                makeSnapshot(
                    cgWindowID: replacementID,
                    titleRead: .unread(.cannotComplete),
                    bounds: originalBounds
                ),
            ],
            allCGWindowIDs: [cgWindowID, replacementID]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[replacementID]?.title, "")
    }

    func testNewSeatDoesNotInheritUnreadTitle() {
        let newWindowID: CGWindowID = 99
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(
            tracker,
            eligible: [
                makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window")),
                makeSnapshot(
                    cgWindowID: newWindowID,
                    titleRead: .unread(.cannotComplete),
                    bounds: CGRect(x: 700, y: 20, width: 500, height: 400)
                ),
            ],
            allCGWindowIDs: [cgWindowID, newWindowID]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[newWindowID]?.title, "")
    }

    func testEventBurstRunsOneLeadingAndExactlyOneTrailingRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { Self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] }
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        tracker.scheduleEventReadForTesting(pid: pid, source: .focusChanged)
        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)

        await waitUntil { reader.readCount == 1 }
        reader.releaseOne()
        await waitUntil { reader.readCount == 2 }
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertEqual(reader.readCount, 2)
    }

    func testFrontmostPollUsesTimedBackgroundReader() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { Self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] }
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleFrontmostPollForTesting(pid: pid)

        await waitUntil { reader.readCount == 1 }
        XCTAssertEqual(reader.untimedReadCount, 0)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pid))

        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }
    }

    func testMinimizeMutationRejectsOlderAsyncRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { Self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] }
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .focusChanged)
        await waitUntil { reader.readCount == 1 }
        tracker.minimizeForTesting(pid: pid, cgWindowID: cgWindowID)
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.isMinimized, true)
    }

    func testDestroyMutationRejectsOlderAsyncRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { Self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] }
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)
        await waitUntil { reader.readCount == 1 }
        tracker.destroyForTesting(pid: pid, cgWindowID: cgWindowID)
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID])
    }

    func testPIDReuseRejectsOlderAsyncRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let processProvider = MutableAppTrackerProcessProvider(pid: pid)
        let tracker = AppTracker(
            reader: reader,
            processProvider: processProvider,
            cgSnapshotProvider: { Self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] }
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        await waitUntil { reader.readCount == 1 }
        processProvider.advanceGeneration()
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID])
    }

    func testEquivalentSnapshotRebuildPublishesOnlyOnce() {
        let tracker = AppTracker()
        tracker.installFixtureForTesting(makeApp())
        var publicationCount = 0
        let subscription = tracker.$snapshot.dropFirst().sink { _ in publicationCount += 1 }

        tracker.rebuildSnapshotForTesting()
        tracker.rebuildSnapshotForTesting()

        XCTAssertEqual(publicationCount, 1)
        withExtendedLifetime(subscription) {}
    }

    private func makeApp(
        isMinimized: Bool = false,
        minAbsentSince: Date? = nil,
        episodeID: UUID? = nil,
        shadowIDs: Set<CGWindowID> = [],
        seatToken: String? = nil
    ) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: seatToken ?? "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: isMinimized,
            isFocused: !isMinimized,
            minAbsentSince: minAbsentSince,
            absenceEpisodeID: episodeID,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false,
            shadowTabCgIDs: shadowIDs
        )
    }

    @discardableResult
    private func reconcileConfirmedTabReplacement(
        _ tracker: AppTracker,
        replacementID: CGWindowID,
        titleRead: AXWindowTitleRead
    ) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        let bounds = CGRect(x: 10, y: 20, width: 500, height: 400)
        tracker.setSubscribedElementForTesting(pid: pid, cgWindowID: cgWindowID,
            element: element, instanceID: 17)
        let request = AbsentSeatProbeRequest(cgWindowID: cgWindowID, seatToken: "tabgrp-\(pid)-s1",
            element: AXElementKey(e: element), instanceID: 17, probeCount: 1)
        let evidence = AbsentSeatProbeEvidence(request: request, element: .alive(minimized: false),
            windowSpaceIDs: [], currentSpaceIDs: [1])
        return tracker.reconcileFixtureForTesting(pid: pid,
            cgSnapshot: AppTrackerCGWindowSnapshot(allWindowIDs: [cgWindowID, replacementID],
                onScreenWindowIDs: [replacementID], windowIDsByPID: [pid: [cgWindowID, replacementID]],
                alphaByWindowID: [cgWindowID: 1, replacementID: 1],
                boundsByWindowID: [cgWindowID: bounds, replacementID: bounds],
                parentWindowIDs: [cgWindowID: 0, replacementID: 0]),
            now: Date(), eligible: [makeSnapshot(cgWindowID: replacementID, titleRead: titleRead, bounds: bounds)],
            readOutcome: .success(count: 1), rawAXCgIDs: [replacementID], absenceEvidence: [cgWindowID: evidence])
    }

    @discardableResult
    private func reconcile(
        _ tracker: AppTracker,
        eligible: [AXWindowSnapshot],
        allCGWindowIDs: Set<CGWindowID>? = nil,
        onScreenCGWindowIDs: Set<CGWindowID>? = nil
    ) -> Bool {
        let ids = allCGWindowIDs ?? Set(eligible.compactMap(\.cgWindowID))
        return tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: AppTrackerCGWindowSnapshot(
                allWindowIDs: ids,
                onScreenWindowIDs: onScreenCGWindowIDs ?? ids,
                windowIDsByPID: [pid: ids],
                alphaByWindowID: [:]
            ),
            now: Date(),
            eligible: eligible,
            readOutcome: .success(count: eligible.count)
        )
    }

    private func makeSnapshot(
        cgWindowID: CGWindowID?,
        titleRead: AXWindowTitleRead,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 500, height: 400),
        element: AXUIElement? = nil,
        isMinimized: Bool = false
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID,
            titleRead: titleRead,
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: isMinimized,
            isFocusedWindow: !isMinimized,
            element: element ?? AXUIElementCreateApplication(pid),
            isMinimizedRead: isMinimized
        )
    }

    private func jsonRecords(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private nonisolated static func emptyCGSnapshot() -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:]
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class ControlledAppTrackerReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var untimedCount = 0
    private let result: AXWindowReadResult
    private let untimedResult: AXWindowReadResult
    private let blocksTimedReads: Bool

    init(
        result: AXWindowReadResult = .unread(.cannotComplete),
        untimedResult: AXWindowReadResult = .unread(.cannotComplete),
        blocksTimedReads: Bool = true
    ) {
        self.result = result
        self.untimedResult = untimedResult
        self.blocksTimedReads = blocksTimedReads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var untimedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return untimedCount
    }

    func releaseOne() {
        semaphore.signal()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        lock.lock()
        untimedCount += 1
        lock.unlock()
        return untimedResult
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        count += 1
        lock.unlock()
        if blocksTimedReads { semaphore.wait() }
        return result
    }
}

private final class MutableAppTrackerProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private var generation: Int64 = 1

    init(pid: pid_t) {
        self.pid = pid
    }

    func advanceGeneration() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isAlive(pid: pid_t) -> Bool { pid == self.pid }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        lock.lock()
        let current = generation
        lock.unlock()
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: current,
            startTimeUsec: 0,
            bundleID: bundleID
        )
    }
}

private struct FixedAppTrackerProcessProvider: AppTrackerProcessProviding {
    let pid: pid_t

    func isAlive(pid: pid_t) -> Bool { pid == self.pid }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: 1,
            startTimeUsec: 2,
            bundleID: bundleID
        )
    }
}

final class WindowLabInputTests: XCTestCase {
    func testIndexOffsetsRejectOutOfRangeValuesBeforeSubtracting() {
        for index in [Int.min, -1, 0, 4, Int.max] {
            XCTAssertNil(WindowLabInput.candidateOffset(String(index), count: 3))
        }
        XCTAssertNil(WindowLabInput.candidateOffset("1", count: 0))
        XCTAssertEqual(WindowLabInput.candidateOffset("1", count: 3), 0)
        XCTAssertEqual(WindowLabInput.candidateOffset("3", count: 3), 2)
    }

    func testCloseVerificationUsesNativeIdentityAndDistinguishesFailedCapture() {
        let sibling: [String: Any] = [
            kCGWindowNumber as String: CGWindowID(20),
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowName as String: "Untitled"
        ]
        let target: [String: Any] = [
            kCGWindowNumber as String: CGWindowID(21),
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowName as String: "Untitled"
        ]
        XCTAssertEqual(WindowLabInput.didClose(windowID: 21, pid: 42, windowInfo: [sibling]), true)
        XCTAssertEqual(WindowLabInput.didClose(windowID: 21, pid: 42, windowInfo: [sibling, target]), false)
        XCTAssertNil(WindowLabInput.didClose(windowID: 21, pid: 42, windowInfo: nil))
    }

    func testNativeAXWindowKeepsItsHistoryWhenRenamedAndResized() {
        var history = AXObservationHistory()
        let hidden = axWindow(title: .value("Old title"))
        let moved = axWindow(title: .value("New title"), bounds: CGRect(x: 40, y: 60, width: 900, height: 700))
        XCTAssertEqual(update(&history, windows: [hidden], isAppHidden: true).map(\.kind), [.hidden])
        let next = update(&history, windows: [moved])
        XCTAssertEqual(next.map(\.kind), [.unhidden])
        XCTAssertEqual(next.first?.title, "New title")
        XCTAssertEqual(next.first?.bounds, moved.bounds)
    }

    func testUnreadAXWindowListPreservesHistoryUntilSuccessfulEmptyRead() {
        var history = AXObservationHistory()
        _ = update(&history, windows: [axWindow(title: .value("Open"))])
        XCTAssertTrue(update(&history, windows: nil).isEmpty)
        let removed = update(&history, windows: [])
        XCTAssertEqual(removed.map(\.kind), [.disappeared])
        XCTAssertEqual(removed.first?.cgWindowID, 21)
    }

    func testUnreadTitleOnKnownAXWindowDoesNotReportDisappearance() {
        var history = AXObservationHistory()
        _ = update(&history, windows: [axWindow(title: .value("Open"))])
        let titleUnread = axWindow(title: .unread(.cannotComplete))
        XCTAssertTrue(update(&history, windows: [titleUnread]).isEmpty)
        let removed = update(&history, windows: [])
        XCTAssertEqual(removed.map(\.kind), [.disappeared])
        XCTAssertEqual(removed.first?.title, "Open")
    }

    func testTemporarilyMissingCGIDPreservesAXWindowAndHiddenState() {
        var history = AXObservationHistory()
        let window = axWindow(title: .value("Open"))
        _ = update(&history, windows: [window], isAppHidden: true)
        let idUnread = axWindow(cgWindowID: nil, title: .value("Renamed"))
        let unhidden = update(&history, windows: [idUnread])
        XCTAssertEqual(unhidden.map(\.kind), [.unhidden])
        XCTAssertEqual(unhidden.first?.cgWindowID, 21)
        XCTAssertEqual(update(&history, windows: [window]).map(\.kind), [.unchanged])
    }

    func testDifferentKnownCGIDTakesPrecedenceOverMatchingAXElement() {
        var history = AXObservationHistory()
        _ = update(&history, windows: [axWindow(title: .value("Open"))], isAppHidden: true)
        let replacement = axWindow(cgWindowID: 22, title: .value("Replacement"))
        let observations = update(&history, windows: [replacement])
        XCTAssertEqual(observations.map(\.kind), [.unchanged, .disappeared])
        XCTAssertEqual(observations.map(\.cgWindowID), [22, 21])
    }

    func testKnownEmptyAXTitleRemovesTheIneligibleWindow() {
        var history = AXObservationHistory()
        _ = update(&history, windows: [axWindow(title: .value("Open"))])
        let removed = update(&history, windows: [axWindow(title: .empty)])
        XCTAssertEqual(removed.map(\.kind), [.disappeared])
        XCTAssertEqual(removed.first?.title, "Open")
    }

    func testMinimizeRequiresSuccessfulCaptureWithoutExactNativeWindow() {
        let target: [String: Any] = [
            kCGWindowNumber as String: CGWindowID(21),
            kCGWindowOwnerPID as String: pid_t(42)
        ]
        XCTAssertFalse(WindowLabInput.didMinimize(windowID: 21, pid: 42, windowInfo: nil))
        XCTAssertTrue(WindowLabInput.didMinimize(windowID: 21, pid: 42, windowInfo: []))
        XCTAssertFalse(WindowLabInput.didMinimize(windowID: 21, pid: 42, windowInfo: [target]))
        XCTAssertTrue(WindowLabInput.didMinimize(windowID: 21, pid: 43, windowInfo: [target]))
    }

    func testReusedCGWindowNumberEndsOldOwnerAndStartsNewOwner() {
        var source = CoreGraphicsSource()
        let now = Date(timeIntervalSince1970: 100)
        func window(pid: pid_t, title: String = "Fixture") -> CoreGraphicsSource.WindowSnapshot {
            CoreGraphicsSource.WindowSnapshot(cgWindowID: 21, pid: pid, bundleIdentifier: "example.app",
                                              appName: "Fixture", title: title, bounds: nil)
        }
        XCTAssertEqual(source.observations(from: [window(pid: 42)], at: now).map(\.kind), [.appeared])
        let replacement = source.observations(from: [window(pid: 43)], at: now)
        XCTAssertEqual(replacement.map(\.kind), [.disappeared, .appeared])
        XCTAssertEqual(replacement.map(\.pid), [42, 43])
        let renamed = source.observations(from: [window(pid: 43, title: "Renamed")], at: now)
        XCTAssertEqual(renamed.map(\.kind), [.titleChanged])
    }

    func testRestoreRequiresCurrentCoreGraphicsRowWithExactIdentity() {
        let identity = WindowID(rawValue: "cg-21")
        func analyzed(
            _ kind: SystemObservation.ObservationKind,
            source: SystemObservation.ObservationSource = .coreGraphics,
            cgWindowID: CGWindowID = 21,
            pid: pid_t = 42,
            windowID: WindowID = WindowID(rawValue: "cg-21"),
            decisionKind: DecisionKind = .knownWindow
        ) -> AnalyzedObservation {
            AnalyzedObservation(
                observation: observation(kind: kind, source: source, cgWindowID: cgWindowID, pid: pid, title: "Open"),
                identity: IdentityDecision(kind: decisionKind, windowID: windowID, confidence: .high, reason: "Fixture")
            )
        }
        let mismatches = [
            analyzed(.disappeared),
            analyzed(.unchanged, source: .accessibility),
            analyzed(.unchanged, cgWindowID: 22),
            analyzed(.unchanged, pid: 43),
            analyzed(.unchanged, windowID: WindowID(rawValue: "other")),
            analyzed(.unchanged, decisionKind: .ambiguous)
        ]
        XCTAssertNil(WindowLabInput.restoredWindow(in: mismatches, identity: identity, windowID: 21, pid: 42))
        let current = analyzed(.appeared)
        XCTAssertEqual(WindowLabInput.restoredWindow(in: mismatches + [current], identity: identity,
                                                    windowID: 21, pid: 42)?.observation, current.observation)
    }

    func testMissingAndUnknownModesFailWithoutStartingObservation() {
        for args in [[], ["typo"], ["--help"]] as [[String]] { XCTAssertThrowsError(try WindowLabInput.mode(args)) }
        XCTAssertEqual(try WindowLabInput.mode(["observe"]), .observe)
    }

    func testScenarioNamesCannotEscapeTheScenarioDirectory() {
        let root = URL(fileURLWithPath: "/fixture")
        for name in ["../outside", "/absolute", "", "a/b", "a\\b", "two..dots"] {
            XCTAssertThrowsError(try WindowLabInput.scenarioURL(root: root, name: name))
        }
        XCTAssertEqual(try WindowLabInput.scenarioURL(root: root, name: "valid-replay_1").path,
            "/fixture/Tools/WindowLab/Scenarios/valid-replay_1.json")
    }

    func testMalformedAndOutOfRangeFramesAreErrorsRatherThanUnknownFrames() throws {
        for frame in ["1:2:3", "1::2:3:4", "nan:1:800:600", "0:0:0:600", "1e30:0:800:600"] {
            XCTAssertThrowsError(try WindowLabInput.bounds(frame))
        }
        XCTAssertNil(try WindowLabInput.bounds(nil))
        XCTAssertEqual(try WindowLabInput.bounds("-2560:30:800:600"), CGRect(x: -2560, y: 30, width: 800, height: 600))
    }

    private func update(
        _ history: inout AXObservationHistory,
        windows: [AXWindowSnapshot]?,
        isAppHidden: Bool = false
    ) -> [SystemObservation] {
        history.update(pid: 42, at: Date(timeIntervalSince1970: 100), isAppHidden: isAppHidden, windows: windows) {
            $0.title != nil
        }
    }

    private func axWindow(
        cgWindowID: CGWindowID? = 21,
        title: AXWindowTitleRead,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(pid: 42, cgWindowID: cgWindowID, titleRead: title, bounds: bounds,
                         role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                         isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(42))
    }

    private func observation(
        kind: SystemObservation.ObservationKind = .unchanged,
        source: SystemObservation.ObservationSource = .accessibility,
        cgWindowID: CGWindowID = 21,
        pid: pid_t = 42,
        title: String,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> SystemObservation {
        SystemObservation(timestamp: Date(timeIntervalSince1970: 100), kind: kind, source: source, pid: pid,
                          bundleIdentifier: "example.app", cgWindowID: cgWindowID, title: title, appName: "Fixture",
                          bounds: bounds, isMinimized: false, isFocusedWindow: false)
    }
}
