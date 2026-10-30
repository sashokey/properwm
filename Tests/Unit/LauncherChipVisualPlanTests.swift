import XCTest
@testable import macos_dock_cc_v2

final class LauncherChipVisualPlanTests: XCTestCase {

    // 运行点是**唯一**的状态信号（2026-08-02 拿掉图标淡化之后）：运行=有点，退出=无点。
    // 与所在分区无关——消息区、抽屉下区、保留图标一视同仁。
    func testRunningDotFollowsProcessStateOnly() {
        XCTAssertTrue(LauncherChipVisualPlan.visual(isRunning: true).showsRunningDot)
        XCTAssertFalse(LauncherChipVisualPlan.visual(isRunning: false).showsRunningDot)
    }
}

final class AppDisplayNameCacheTests: XCTestCase {
    func testSuccessfulResolutionIsCached() {
        let cache = AppDisplayNameCache()
        var loads = 0

        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return "Example" }, "Example")
        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return "Changed" }, "Example")
        XCTAssertEqual(loads, 1)
    }

    func testFailedResolutionIsNotCached() {
        let cache = AppDisplayNameCache()
        var loads = 0

        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return nil }, "com.example.app")
        XCTAssertEqual(cache.value(for: "com.example.app") { loads += 1; return "Example" }, "Example")
        XCTAssertEqual(loads, 2)
    }

    func testInvalidationOnlyClearsTheNamedBundle() {
        let cache = AppDisplayNameCache()
        _ = cache.value(for: "com.example.a") { "A" }
        _ = cache.value(for: "com.example.b") { "B" }
        cache.invalidate(bundleID: "com.example.a")

        XCTAssertEqual(cache.value(for: "com.example.a") { "A2" }, "A2")
        XCTAssertEqual(cache.value(for: "com.example.b") { "B2" }, "B")
    }
}
