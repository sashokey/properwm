import CoreGraphics
import XCTest

final class WindowFocusTests: XCTestCase {
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
