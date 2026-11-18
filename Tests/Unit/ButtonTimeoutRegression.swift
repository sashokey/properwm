import ApplicationServices
import Foundation
import Synchronization
import XCTest

private final class ButtonTimeoutAccessibility: AccessibilityOperations {
    private struct State {
        var timeouts: [AXElementKey: Float] = [:]
        var pressedWithoutTimeout: [String] = []
        var minimized = false
        var pressCount = 0
    }

    let window = AXElementKey(e: AXUIElementCreateApplication(-421001))
    let closeButton = AXElementKey(e: AXUIElementCreateApplication(-421002))
    let minimizeButton = AXElementKey(e: AXUIElementCreateApplication(-421003))
    private let state = Mutex(State())
    let cancellationOnRead: OperationCancellation?
    let failButtonTimeout: Bool
    let onButtonRead: @Sendable () -> Void

    init(cancellationOnRead: OperationCancellation? = nil, failButtonTimeout: Bool = false,
         onButtonRead: @escaping @Sendable () -> Void = {}) {
        self.cancellationOnRead = cancellationOnRead
        self.failButtonTimeout = failButtonTimeout
        self.onButtonRead = onButtonRead
    }

    var missingTimeouts: [String] { state.withLock { $0.pressedWithoutTimeout } }
    var pressCount: Int { state.withLock { $0.pressCount } }

    func isTrusted() -> Bool { true }
    func application(_ pid: pid_t) -> AXUIElement { window.e }
    func pid(_ element: AXUIElement) -> pid_t? { -42000 }
    func windowID(_ element: AXUIElement) -> CGWindowID? { 1001 }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) { (.success, true) }

    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError {
        if failButtonTimeout, AXElementKey(e: element) != window { return .failure }
        state.withLock { $0.timeouts[AXElementKey(e: element)] = timeout }
        return .success
    }

    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        if attribute as String == kAXCloseButtonAttribute as String
            || attribute as String == kAXMinimizeButtonAttribute as String {
            cancellationOnRead?.cancel()
            onButtonRead()
        }
        switch attribute as String {
        case kAXCloseButtonAttribute: return (.success, closeButton.e)
        case kAXMinimizeButtonAttribute: return (.success, minimizeButton.e)
        case kAXMinimizedAttribute:
            return (.success, state.withLock { $0.minimized } ? kCFBooleanTrue : kCFBooleanFalse)
        default: return (.attributeUnsupported, nil)
        }
    }

    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        .attributeUnsupported
    }

    func perform(_ element: AXUIElement, _ action: CFString) -> AXError {
        guard action as String == kAXPressAction as String else { return .actionUnsupported }
        let key = AXElementKey(e: element)
        let name = key == closeButton ? "close" : key == minimizeButton ? "minimize" : "unknown"
        state.withLock {
            $0.pressCount += 1
            if ($0.timeouts[key] ?? 0) <= 0 { $0.pressedWithoutTimeout.append(name) }
            if key == minimizeButton { $0.minimized = true }
        }
        return .success
    }
}

final class ButtonTimeoutRegressionTests: XCTestCase {
    private func fixture(accessibility: ButtonTimeoutAccessibility = ButtonTimeoutAccessibility(),
                         cancellation: OperationCancellation = OperationCancellation(),
                         budget: OperationReadBudget? = nil) -> (ButtonTimeoutAccessibility, AccessibilityWindowActionExecutor, AccessibilityWindowActionExecutor.WindowHandle) {
        let reader = AXWindowReader(accessibility: accessibility)
        let executor = AccessibilityWindowActionExecutor(reader: reader, cancellation: cancellation, budget: budget)
        let handle = AccessibilityWindowActionExecutor.fastHandle(
            from: AXWindowHandle(pid: -42000, title: "Fixture", bounds: nil, element: accessibility.window.e),
            target: .init(pid: -42000, title: "Fixture", bounds: nil, cgWindowID: 1001)
        )
        return (accessibility, executor, handle)
    }

    func testCloseButtonHasAnExplicitTimeoutBeforePress() {
        let (accessibility, executor, handle) = fixture()
        XCTAssertTrue(executor.close(handle))
        XCTAssertEqual(accessibility.pressCount, 1)
        XCTAssertTrue(accessibility.missingTimeouts.isEmpty, "AXPressAction used an element with no explicit messaging timeout: \(accessibility.missingTimeouts)")
    }

    func testMinimizeButtonHasAnExplicitTimeoutBeforePress() {
        let (accessibility, executor, handle) = fixture()
        let result = executor.minimize(handle)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.verifiedMinimized, true)
        XCTAssertEqual(accessibility.pressCount, 1)
        XCTAssertTrue(accessibility.missingTimeouts.isEmpty, "AXPressAction used an element with no explicit messaging timeout: \(accessibility.missingTimeouts)")
    }

    func testFailedButtonTimeoutSetupPreventsBothPressActions() {
        for close in [true, false] {
            let (accessibility, executor, handle) = fixture(accessibility: ButtonTimeoutAccessibility(failButtonTimeout: true))
            XCTAssertFalse(close ? executor.close(handle) : executor.minimize(handle).success)
            XCTAssertEqual(accessibility.pressCount, 0)
        }
    }

    func testCancellationDuringButtonReadPreventsBothPressActions() {
        for close in [true, false] {
            let cancellation = OperationCancellation()
            let (accessibility, executor, handle) = fixture(
                accessibility: ButtonTimeoutAccessibility(cancellationOnRead: cancellation), cancellation: cancellation)
            XCTAssertFalse(close ? executor.close(handle) : executor.minimize(handle).success)
            XCTAssertEqual(accessibility.pressCount, 0)
        }
    }

    func testBudgetExpiryDuringButtonReadPreventsBothPressActions() {
        for close in [true, false] {
            let now = Mutex<TimeInterval>(0)
            let cancellation = OperationCancellation()
            let budget = OperationReadBudget(maximumDuration: 0.05, cancellation: cancellation, uptime: { now.withLock { $0 } })
            let (accessibility, executor, handle) = fixture(
                accessibility: ButtonTimeoutAccessibility(onButtonRead: { now.withLock { $0 = 1 } }),
                cancellation: cancellation, budget: budget)
            XCTAssertFalse(close ? executor.close(handle) : executor.minimize(handle).success)
            XCTAssertEqual(accessibility.pressCount, 0)
        }
    }
}
