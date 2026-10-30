import XCTest

final class FullscreenClassificationTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // LaunchOS's full-screen launcher (probed 2026-10-16): role AXWindow / subrole AXSystemDialog, frame equal
    // to the whole screen, CG layer 1000, no AXFullScreen flag. The frame fallback hides the bar for it, and
    // closing it fires no activation change — `OverlayWindowWatch` below is what ends that hide.
    func testScreenSizedOverlayWithoutAXFlagIsFullscreen() {
        XCTAssertEqual(FullscreenWindowClassifier.classify(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen, windowLayer: 1000, screenCGFrame: screen),
            .fullscreen)
    }

    func testOverlayWatchKeepsWaitingWhileTheWindowStillCoversTheScreen() {
        XCTAssertFalse(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: screen, screenCGFrame: screen))
        let nudged = screen.insetBy(dx: 2, dy: 2)
        XCTAssertFalse(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: nudged, screenCGFrame: screen))
    }

    func testOverlayWatchRechecksWhenTheWindowIsGoneOrOrderedOut() {
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: nil, bounds: nil, screenCGFrame: screen))
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: false, bounds: screen, screenCGFrame: screen))
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: nil, screenCGFrame: screen))
    }

    func testOverlayWatchRechecksWhenTheWindowStopsCoveringTheScreen() {
        let shrunk = CGRect(x: 100, y: 80, width: 1200, height: 800)
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: shrunk, screenCGFrame: screen))
        let moved = screen.offsetBy(dx: 1512, dy: 0)
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: moved, screenCGFrame: screen))
    }

    // 回归：Finder 桌面伪窗口（role=AXScrollArea，frame 恰好等于整屏）不得判为全屏
    func testDesktopPseudoWindowWithExactScreenFrameIsNotFullscreen() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXScrollArea", isAXFullscreen: false, windowFrame: screen, windowLayer: 0, screenCGFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithExactScreenFrame() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: nil, isAXFullscreen: false, windowFrame: screen, windowLayer: 0, screenCGFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithAXFullscreenFlag() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: nil, isAXFullscreen: true, windowFrame: nil, windowLayer: 0, screenCGFrame: screen))
    }

    func testNativeFullscreenWindowIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen, windowLayer: 0, screenCGFrame: screen))
    }

    func testNativeFullscreenWithUnreadableFrameIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: nil, windowLayer: 0, screenCGFrame: screen))
    }

    func testNativeFullscreenOnAnotherScreenIsNotFullscreenHere() {
        let otherScreen = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: otherScreen, windowLayer: 0, screenCGFrame: screen))
    }

    // 全屏幕拼贴（真分屏）：AXFullScreen=true 但只有半屏宽（2026-08-30 实测形状按比例缩到测试屏）。
    // 修掉的正是旧宽度条款（width > screen×0.7）把它误否、任务条盖在分屏内容上。
    func testSplitViewTileOnThisScreenIsFullscreen() {
        let leftTile = CGRect(x: 0, y: 20, width: 754, height: 962)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: leftTile, windowLayer: 0, screenCGFrame: screen))
        let rightTile = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: rightTile, windowLayer: 0, screenCGFrame: screen))
    }

    // 多屏护栏的接棒者：窗口主体在邻屏、只蹭进本屏几十点，不得判为本屏的全屏。
    // 旧宽度条款曾顺带挡住这类窗口；换成面积归属后由本用例钉住这个行为。
    func testFullscreenWindowMostlyOnNeighborScreenIsNotFullscreenHere() {
        let mostlyElsewhere = CGRect(x: 1480, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: mostlyElsewhere, windowLayer: 0, screenCGFrame: screen))
    }

    // 桌面平铺（26 的默认「分屏」）：半宽但 AXFullScreen=false，走 frame 兜底，不得判为全屏——
    // 它是普通桌面上的普通窗口，条照常显示（那一半的遮挡归避让议题，不归隐藏）。
    func testDesktopTiledHalfWindowIsNotFullscreen() {
        let tiled = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: tiled, windowLayer: 0, screenCGFrame: screen))
    }

    // 无 AXFullScreen 标志的无边框全屏（游戏/HTML5）仍走 frame≈整屏兜底
    func testBorderlessScreenSizedWindowIsFullscreen() {
        let nearScreen = screen.insetBy(dx: 2, dy: 2)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nearScreen, windowLayer: 0, screenCGFrame: screen))
    }

    // Regression (feedback 652f4dc8): an accessory app's screen-sized window at desktop level takes
    // focus when the desktop is clicked; the frame fallback must not read it as fullscreen.
    func testScreenSizedWindowBelowNormalLayerIsNotFullscreen() {
        let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: desktopIconLayer, screenCGFrame: screen))
        XCTAssertEqual(
            FullscreenWindowClassifier.classify(
                role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
                windowLayer: -1, screenCGFrame: screen),
            .windowed)
    }

    // An unreadable layer keeps the old verdict, and games above the normal layer still hide the bar.
    func testScreenSizedWindowWithUnknownOrRaisedLayerIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: nil, screenCGFrame: screen))
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: Int(CGWindowLevelForKey(.screenSaverWindow)), screenCGFrame: screen))
    }

    // The layer guard belongs to the frame fallback only: a native fullscreen flag is never overruled.
    func testNativeFullscreenFlagIgnoresLayer() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen,
            windowLayer: -1, screenCGFrame: screen))
    }

    func testOrdinaryWindowIsNotFullscreen() {
        let partial = CGRect(x: 253, y: 125, width: 1127, height: 689)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: partial, windowLayer: 0, screenCGFrame: screen))
    }

    func testRealWindowWithUnreadableFrameIsNotFullscreen() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nil, windowLayer: 0, screenCGFrame: screen))
    }

    // MARK: - 常驻所有桌面的成员资格（issue #19）

    func testMembershipIsHealthyWhenWindowCoversEveryDesktop() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1020], desktopSpaceIDs: [1, 3, 1020]),
            [])
    }

    // 这就是 issue #19 的症状：退全屏之后只剩当前桌面
    func testMembershipCollapsedToCurrentDesktopIsReported() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: [1, 3, 1020]),
            [3, 1020])
    }

    // 窗口多挂了一个全屏空间不算问题（进全屏那一瞬间就是这个样子）
    func testExtraFullscreenSpaceMembershipIsNotAProblem() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1013], desktopSpaceIDs: [1, 3]),
            [])
    }

    // 单桌面谈不上「丢桌面」，永远不要触发修复
    func testSingleDesktopNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [], desktopSpaceIDs: [1]),
            [])
    }

    func testEmptyDesktopListNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: []),
            [])
    }

    // 修复单次不保证成功，必须允许重试，但不能无限重试
    func testRepairRetriesAreBounded() {
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 0))
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 2))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 3))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 4))
    }
}
