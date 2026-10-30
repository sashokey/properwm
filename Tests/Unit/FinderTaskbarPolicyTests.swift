import XCTest

final class FinderTaskbarPolicyTests: XCTestCase {

    func testIsFinderMatchesOnlyFinder() {
        XCTAssertTrue(FinderTaskbarPolicy.isFinder("com.apple.finder"))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder("com.apple.finder.helper"))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder(nil))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder(""))
    }

    /// 取消勾选「在程序坞中保留」后，访达的应用级入口就不再显示——这就是整个功能的闸门。
    func testAppLevelEntryFollowsKept() {
        XCTAssertTrue(FinderTaskbarPolicy.showsAppLevelEntry(isKept: true))
        XCTAssertFalse(FinderTaskbarPolicy.showsAppLevelEntry(isKept: false))
    }

    /// 抽屉与保留都放开了，消息区仍然不放开。
    func testMessagingStaysClosedToFinder() {
        XCTAssertFalse(FinderTaskbarPolicy.canMarkMessaging(FinderTaskbarPolicy.bundleID))
        XCTAssertFalse(FinderTaskbarPolicy.canMarkMessaging(""))
        XCTAssertTrue(FinderTaskbarPolicy.canMarkMessaging("com.example.chat"))
    }
}
