import XCTest

final class PanelVisibilityStateTests: XCTestCase {
    func testWindowedTaskbarIsAlwaysVisible() {
        XCTAssertTrue(PanelVisibilityState().isVisible)
    }

    func testFullscreenHidesAndExitingRestoresVisibility() {
        var state = PanelVisibilityState()
        state.setFullscreen(true)
        XCTAssertFalse(state.isVisible)
        state.setFullscreen(false)
        XCTAssertTrue(state.isVisible)
    }

    func testPredictedTransitionHidesBeforeConfirmation() {
        var state = PanelVisibilityState()
        state.beginFullscreenTransition(generation: 1)
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.confirmFullscreenTransition(generation: 1))
        XCTAssertNil(state.fullscreenTransitionGeneration)
        XCTAssertEqual(state.hideReasons, [.fullscreen])
        state.setFullscreen(false)
        XCTAssertTrue(state.isVisible)
    }

    func testStaleTimeoutCannotRevealNewerTransition() {
        var state = PanelVisibilityState()
        state.beginFullscreenTransition(generation: 1)
        state.beginFullscreenTransition(generation: 2)
        XCTAssertFalse(state.timeoutFullscreenTransition(generation: 1))
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.timeoutFullscreenTransition(generation: 2))
        XCTAssertTrue(state.isVisible)
    }

    func testStaleConfirmationCannotHideAfterCancelledPrediction() {
        var state = PanelVisibilityState()
        state.beginFullscreenTransition(generation: 1)
        XCTAssertTrue(state.timeoutFullscreenTransition(generation: 1))
        XCTAssertFalse(state.confirmFullscreenTransition(generation: 1))
        XCTAssertTrue(state.isVisible)
    }

    func testTimeoutKeepsIndependentlyConfirmedFullscreenHidden() {
        var state = PanelVisibilityState()
        state.setFullscreen(true)
        state.beginFullscreenTransition(generation: 2)
        XCTAssertTrue(state.timeoutFullscreenTransition(generation: 2))
        XCTAssertFalse(state.isVisible)
        state.setFullscreen(false)
        XCTAssertTrue(state.isVisible)
    }
}
