import XCTest

/// 角标读取计划判定矩阵：pause 优先级、各全走树原因、定点读透传、10s 自愈边界。
final class BadgeReadPlanTests: XCTestCase {
    private func input(
        messagingBundleIDs: [String] = ["com.tencent.xinWeChat"],
        taskbarVisible: Bool = true,
        hasCache: Bool = true,
        cacheAgeSeconds: TimeInterval = 3,
        rewalkRequested: Bool = false
    ) -> BadgeReadPlan.Input {
        BadgeReadPlan.Input(
            messagingBundleIDs: messagingBundleIDs,
            taskbarVisible: taskbarVisible,
            hasCache: hasCache,
            cacheAgeSeconds: cacheAgeSeconds,
            rewalkRequested: rewalkRequested
        )
    }

    func testEmptyMessagingListPausesBeforeEverything() {
        // pause 优先于走树：没有可读对象时连缓存重建都不做（零 AX 流量）。
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(messagingBundleIDs: [], hasCache: false, rewalkRequested: true)),
            .pause
        )
    }

    func testHiddenTaskbarPausesBeforeEverything() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(taskbarVisible: false, hasCache: false, rewalkRequested: true)),
            .pause
        )
    }

    func testMissingCacheWalks() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(hasCache: false)),
            .fullWalk(.noCache)
        )
    }

    func testRequestedRewalkWalks() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(rewalkRequested: true)),
            .fullWalk(.rewalkRequested)
        )
    }

    func testSelfHealBoundaryIsInclusive() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(cacheAgeSeconds: BadgeReadPlan.defaultFullWalkInterval)),
            .fullWalk(.selfHealDue)
        )
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(cacheAgeSeconds: BadgeReadPlan.defaultFullWalkInterval - 0.001)),
            .targeted(["com.tencent.xinWeChat"])
        )
    }

    func testQuietTickReadsTargetedMessagingSet() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(messagingBundleIDs: ["a", "b"])),
            .targeted(["a", "b"])
        )
    }
}
