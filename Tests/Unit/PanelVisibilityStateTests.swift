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

}
