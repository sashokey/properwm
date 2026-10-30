import XCTest

final class DragConversionPlanTests: XCTestCase {

    // MARK: - drawerDragOutMode

    func testEmptyBundleIDRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: true), .reject)
    }

    /// 2026-08-20：访达可以进抽屉，也就可以像普通应用一样拖回任务条。
    func testFinderDragsOutLikeAnOrdinaryApp() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: FinderTaskbarPolicy.bundleID, isMessagingMember: false,
            isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: true), .unstash)
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: FinderTaskbarPolicy.bundleID, isMessagingMember: false,
            isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: true), .keepPlacement)
    }

    func testRunningMessagingMemberReleasesToMessaging() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: false), .releaseToMessaging)
    }

    /// 消息判定必须先于真窗口判定：运行中的消息应用有主窗口,不能误入 unstash。
    func testMessagingPrecedesRealWindowCheck() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: false), .releaseToMessaging)
    }

    /// 既没在跑、也没勾保留才拒收——那种情况释放过去确实会凭空消失。
    func testMessagingMemberNeitherRunningNorKeptRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: false, hasRealWindow: false, isKept: false), .reject)
    }

    /// **回归锁**：进程在跑、但窗口清单里没有它（微信主窗口关着就是这样）——必须能释放。
    /// 判据要和消息区自己的可见规则同源，不能判窗口清单（owner 2026-08-20 实测，日志实证）。
    func testRunningWithNoTrackedWindowStillReleases() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.tencent.xinWeChat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: true, hasRealWindow: false, isKept: false), .releaseToMessaging)
    }

    /// 没在跑但勾了保留：消息区照样显示它（统一保留模型），所以也能释放回去。
    func testKeptButNotRunningMessagingMemberReleases() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: false, hasRealWindow: false, isKept: true), .releaseToMessaging)
    }

    func testRealWindowUnstashes() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: false), .unstash)
    }

    func testKeptAppWithoutSnapshotUsesKeepPlacement() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: false, isRunningProcess: false, hasRealWindow: false, isKept: true), .keepPlacement)
    }

    func testRunningFallbackUsesKeepPlacementWithoutKept() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: false), .keepPlacement)
    }

    func testInactiveUncheckedPlacementRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: false, isRunningProcess: false, hasRealWindow: false, isKept: false), .reject)
    }

    // MARK: - endAction

    func testStripAndFolderNeverRouteHere() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .strip, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .none)
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .folder, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .none)
    }

    func testMessagingChipOverDropZoneStashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .messaging, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: true), .stashMessagingChip)
    }

    /// 消息 chip 在桌面/文件夹区/live 区（都不是投放区）松手 → 原地不动。
    func testMessagingChipOutsideDropZoneDoesNothing() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .messaging, isConvertedToStrip: false, isOverDropZone: false, isMessagingMember: true), .none)
    }

    func testConvertedDrawerDragCommits() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: true, isOverDropZone: true, isMessagingMember: false), .commitDrawerToStrip)
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: true, isOverDropZone: false, isMessagingMember: false), .commitDrawerToStrip)
    }

    func testUnconvertedDrawerDropOnStripFallbackUnstashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .fallbackUnstash)
    }

    /// 消息成员的抽屉图标永不走降级 unstash：任务条上（消息区范围外）松手 → 留在抽屉。
    func testMessagingMemberNeverFallbackUnstashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: true), .none)
    }

    func testUnconvertedDrawerDropOutsideDoesNothing() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: false, isMessagingMember: false), .none)
    }

    // MARK: - 拖入抽屉落定 → 自动打开 kept

    /// 从抽屉外（任务条 / 消息区）带进来才打开。
    func testDropFromOutsideIntoDrawerEnablesKept() {
        XCTAssertTrue(DragConversionPlan.enablesKeptOnDrop(originSource: .strip, endedInDrawer: true))
        XCTAssertTrue(DragConversionPlan.enablesKeptOnDrop(originSource: .messaging, endedInDrawer: true))
    }

    /// 起拖来源就是抽屉 = 它本来就在里面（抽屉内重排、转正撤回），不是「拖入」。
    func testDragStartingInDrawerNeverEnablesKept() {
        XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: .drawer, endedInDrawer: true))
    }

    /// 文件夹 chip 与收纳语义完全隔离，永不进这条路。
    func testFolderDragNeverEnablesKept() {
        XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: .folder, endedInDrawer: true))
    }

    /// 落定后不在抽屉里 → 一律不打开，不管从哪儿来（撤销、降级移出、转正进任务条都走这支）。
    func testNotEndingInDrawerNeverEnablesKept() {
        for source in [DragSource.strip, .drawer, .folder, .messaging] {
            XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: source, endedInDrawer: false))
        }
    }
}
