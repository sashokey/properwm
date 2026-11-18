import CoreGraphics
import ApplicationServices
import Synchronization
import XCTest

final class WindowFocusTests: XCTestCase {
    func testMinimizedWindowCanRestoreWithExactAccessibilityIdentityWhenWindowServerOmitsIt() {
        let start = ProcessGeneration(timeval(tv_sec: 10, tv_usec: 3))
        let record = WindowRecord(id: WindowID(rawValue: "one"), appID: AppID(rawValue: "app"), pid: 42,
            bundleIdentifier: "test.app", title: "Window", bounds: nil, status: .minimized, cgWindowID: 100,
            processGeneration: start)
        XCTAssertTrue(WindowCommandIdentity.permits(record, currentGeneration: start, ownerPID: nil,
            accessibilityOwnerPID: 42, accessibilityWindowID: 100))
    }

    func testMissingWindowServerEntryStillRejectsWrongOrUnreadAccessibilityIdentity() {
        let start = ProcessGeneration(timeval(tv_sec: 10, tv_usec: 3))
        let record = WindowRecord(id: WindowID(rawValue: "one"), appID: AppID(rawValue: "app"), pid: 42,
            bundleIdentifier: "test.app", title: "Window", bounds: nil, status: .minimized, cgWindowID: 100,
            processGeneration: start)
        for (owner, window): (Int32?, CGWindowID?) in [(nil, nil), (42, nil), (nil, 100), (43, 100), (42, 101)] {
            XCTAssertFalse(WindowCommandIdentity.permits(record, currentGeneration: start, ownerPID: nil,
                accessibilityOwnerPID: owner, accessibilityWindowID: window))
        }
        XCTAssertFalse(WindowCommandIdentity.permits(record, currentGeneration: nil, ownerPID: nil,
            accessibilityOwnerPID: 42, accessibilityWindowID: 100))
        XCTAssertFalse(WindowCommandIdentity.permits(record,
            currentGeneration: ProcessGeneration(timeval(tv_sec: 11, tv_usec: 3)), ownerPID: nil,
            accessibilityOwnerPID: 42, accessibilityWindowID: 100))
        XCTAssertFalse(WindowCommandIdentity.permits(record, currentGeneration: start, ownerPID: 43,
            accessibilityOwnerPID: 42, accessibilityWindowID: 100))
    }

    func testDeniedAuthorizationPreventsEveryMutationIncludingEarlyFocus() {
        let calls = Mutex(0)
        let backend = SkyLightWindowFocus(frontRequest: { _, _, _ in calls.withLock { $0 += 1 }; return 0 },
            keyRequest: { _, _ in calls.withLock { $0 += 1 }; return 0 })
        let executor = AccessibilityWindowActionExecutor(focusBackend: backend)
            .withCancellation(OperationCancellation(), authorization: { _, _, _ in false })
        let handle = AccessibilityWindowActionExecutor.fastHandle(
            from: AXWindowHandle(pid: -42, title: nil, bounds: nil, element: AXUIElementCreateApplication(-42)),
            target: .init(pid: -42, title: nil, bounds: nil, cgWindowID: 100))
        XCTAssertFalse(executor.requestWindowFocusViaSkyLight(handle))
        XCTAssertFalse(executor.activate(handle))
        XCTAssertFalse(executor.minimize(handle).success)
        XCTAssertFalse(executor.close(handle))
        XCTAssertFalse(executor.activateApplication(pid: -42))
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testHelperActivationRequiresTheObservedAccessibilityWindow() throws {
        let desktop = BehaviorDesktop()
        let original = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let element = try XCTUnwrap(desktop.elements[1001])
        let generation = try XCTUnwrap(original.processGeneration)
        let hostOrigin = try XCTUnwrap(desktop.app(-42000)?.origin)
        let record = WindowRecord(id: original.id, appID: original.appID, pid: original.pid,
            bundleIdentifier: original.bundleIdentifier, title: original.title, bounds: original.bounds,
            status: .inactive, cgWindowID: 1001, processGeneration: generation,
            owningApplication: ApplicationIdentity(pid: -42000, bundleIdentifier: "test.Browser",
                origin: hostOrigin, generation: generation),
            actionTarget: WindowActionTarget(element: AXElementKey(e: element)))
        let snapshot = DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id])
        let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: desktop),
            system: desktop, focusBackend: desktop)
        desktop.state.withLock {
            $0.frontmostPIDOverride = -42000
            $0.exposesSystemFocus = true
            $0.denyFocus = true
            $0.nativeWindowIDOverrides[1002] = 1001
            $0.publishedFocusedWindows[record.pid] = 1002
        }

        for (focused, succeeds): (CGWindowID, Bool) in [(1001, true), (1002, false)] {
            desktop.state.withLock { $0.focused = focused }
            XCTAssertEqual(executor.execute(.init(kind: .activateWindow, windowID: record.id),
                snapshot: snapshot, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                onHandoffActivePrediction: nil), succeeds)
        }
    }

    func testMinimizedRestoreCarriesItsAccessibilityElementIntoFocusAuthorization() {
        let calls = Mutex<[String]>([])
        let backend = SkyLightWindowFocus(frontRequest: { _, window, _ in
            calls.withLock { $0.append("front:\(window)") }
            return 0
        }, keyRequest: { _, window in
            calls.withLock { $0.append("key:\(window)") }
            return 0
        })
        let executor = AccessibilityWindowActionExecutor(focusBackend: backend)
            .withCancellation(OperationCancellation(), authorization: { pid, window, element in
                pid == -42 && window == 100 && element != nil
            })
        let handle = AccessibilityWindowActionExecutor.fastHandle(
            from: AXWindowHandle(pid: -42, title: nil, bounds: nil, element: AXUIElementCreateApplication(-42)),
            target: .init(pid: -42, title: nil, bounds: nil, cgWindowID: 100))
        XCTAssertFalse(executor.activate(handle, confirmationTimeout: 0, knownCGWindowID: 100,
            knownMinimized: true, preActivateForRestore: true))
        XCTAssertTrue(calls.withLock { $0.contains("front:100") })
        XCTAssertTrue(calls.withLock { $0.contains("key:100") })
    }

    func testCommandsRequireTheCapturedProcessGenerationAndWindowOwner() {
        let start = ProcessGeneration(timeval(tv_sec: 10, tv_usec: 3))
        let record = WindowRecord(id: WindowID(rawValue: "one"), appID: AppID(rawValue: "app"), pid: 42,
            bundleIdentifier: "test.app", title: "Window", bounds: nil, status: .inactive, cgWindowID: 100,
            processGeneration: start)
        XCTAssertTrue(WindowCommandIdentity.permits(record, currentGeneration: start, ownerPID: 42))
        XCTAssertFalse(WindowCommandIdentity.permits(record, currentGeneration: nil, ownerPID: 42))
        XCTAssertFalse(WindowCommandIdentity.permits(record,
            currentGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 4)), ownerPID: 42))
        XCTAssertFalse(WindowCommandIdentity.permits(record, currentGeneration: start, ownerPID: 43))
        XCTAssertFalse(WindowCommandIdentity.permits(record, currentGeneration: start, ownerPID: nil))
        var unknown = record
        unknown.processGeneration = nil
        XCTAssertFalse(WindowCommandIdentity.permits(unknown, currentGeneration: start, ownerPID: 42))
    }

    func testNativeStatusesAndUnavailableSymbolsAreNotReportedAsSuccess() {
        for status in [nil, CGError.failure.rawValue, CGError.illegalArgument.rawValue, CGError.success.rawValue] as [Int32?] {
            let backend = SkyLightWindowFocus(frontRequest: { _, _, _ in status }, keyRequest: { _, _ in status })
            XCTAssertEqual(backend.setFrontmost(pid: 42, windowID: 101, mode: 0x200), status == CGError.success.rawValue)
            XCTAssertEqual(backend.makeKey(pid: 42, windowID: 101), status == CGError.success.rawValue)
        }
    }

    func testAcceptedButIneffectivePrivateFocusUsesFallbackAndVerifiesIt() {
        var calls: [String] = []
        var confirmations = 0
        let success = WindowActivationAttempt.run(
            requestPrivateFocus: { calls.append("private"); return true },
            raise: { calls.append("raise") },
            activateApplication: { calls.append("fallback") },
            confirm: { _ in
                calls.append("confirm")
                confirmations += 1
                return confirmations == 2
            }, timeout: 0.2)
        XCTAssertTrue(success)
        XCTAssertEqual(calls, ["private", "raise", "confirm", "fallback", "raise", "confirm"])
    }

    func testFailedRequestsCannotSucceedWithoutObservedFocus() {
        for accepted in [false, true] {
            var fallbackCalls = 0
            XCTAssertFalse(WindowActivationAttempt.run(requestPrivateFocus: { accepted }, raise: {},
                activateApplication: { fallbackCalls += 1 }, confirm: { _ in false }, timeout: 0.2))
            XCTAssertEqual(fallbackCalls, 1)
        }
    }

    func testConfirmedExactWindowDoesNotActivateAllApplicationWindows() {
        var fallbackCalls = 0
        XCTAssertTrue(WindowActivationAttempt.run(requestPrivateFocus: { true }, raise: {},
            activateApplication: { fallbackCalls += 1 }, confirm: { _ in true }, timeout: 0.2))
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testRejectedPrivateRequestDoesNotWaitBeforeTheFallback() {
        var budgets: [TimeInterval] = []
        XCTAssertFalse(WindowActivationAttempt.run(requestPrivateFocus: { false }, raise: {}, activateApplication: {},
            confirm: { budgets.append($0); return false }, timeout: 0.2))
        XCTAssertEqual(budgets, [0, 0.2])
    }
}
