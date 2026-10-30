import ApplicationServices
import CoreGraphics
import XCTest

/// AX 元素旁路缓存的存取与失效规则。
///
/// 这条规则一旦写错有两个方向的坏结果，方向相反、都很难看出来：
/// - 留下指向已销毁窗口的陈旧元素 → cgWindowID 复用后可能操作到**别的窗口**；
/// - 把最小化后离开 `AXWindows` 的窗口误删 → 缓存在最该发挥作用的时刻恰好是空的，白建。
final class AXElementCacheTests: XCTestCase {

    // MARK: - 保留判定

    /// 出列只认 **CG 全列表**：CG 里没有了才是真关掉了。
    func testExpiredIsExactlyWhatLeftTheCGList() {
        let expired = AXElementCacheRetention.expired(
            cachedCGWindowIDs: [1, 2, 3],
            liveCGWindowIDs: [2, 3, 4]
        )
        XCTAssertEqual(expired, [1])
    }

    /// **仍在 CG 里就必须留着**，哪怕这一轮 AX 完全没报到它。
    /// Safari 系窗口最小化后会整个从 `AXWindows` 里消失（幽灵座位自愈那条规则的前提），
    /// 而那正是「点最小化的窗口点回来」要用缓存的时刻。按 AX 缺席删 = 缓存对最该救的场景失效。
    func testWindowStillInCGListSurvivesEvenWhenAXNoLongerReportsIt() {
        let expired = AXElementCacheRetention.expired(
            cachedCGWindowIDs: [7],
            liveCGWindowIDs: [7]
        )
        XCTAssertTrue(expired.isEmpty)
    }

    func testEmptyCacheExpiresNothing() {
        XCTAssertTrue(
            AXElementCacheRetention.expired(cachedCGWindowIDs: [], liveCGWindowIDs: [1, 2]).isEmpty
        )
    }

    /// CG 全列表读空（极端情况）时，缓存整体作废——这与「CG 在场才保住座位」的既有规则同向。
    func testEmptyLiveListExpiresEverything() {
        XCTAssertEqual(
            AXElementCacheRetention.expired(cachedCGWindowIDs: [1, 2], liveCGWindowIDs: []),
            [1, 2]
        )
    }

    // MARK: - 存取

    func testStoreAndLookupIsKeyedByPidAndWindow() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 42, cgWindowID: 7, element: element)

        XCTAssertNotNil(cache.element(pid: 42, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 8), "同 pid 不同窗口不能串")
        XCTAssertNil(cache.element(pid: 43, cgWindowID: 7), "同窗口号不同 pid 不能串")
    }

    /// `pid <= 0` 与 `cgWindowID == 0` 都不是有效身份，写进去就是给自己埋雷。
    func testInvalidIdentitiesAreRejectedOnStoreAndLookup() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 0, cgWindowID: 7, element: element)
        cache.store(pid: -1, cgWindowID: 7, element: element)
        cache.store(pid: 42, cgWindowID: 0, element: element)

        XCTAssertEqual(cache.countForTesting, 0)
        XCTAssertNil(cache.element(pid: 0, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 0))
    }

    func testRemoveAllDropsOnlyThatProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 3, element: element)

        cache.removeAll(pid: 42)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 2))
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 3))
    }

    /// `retain` 是按 pid 生效的：另一个进程的条目不能被这一轮对账顺手清掉
    /// （每轮对账只拿到当前 pid 的上下文）。
    func testRetainOnlyPrunesTheGivenProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 1, element: element)

        cache.retain(pid: 42, liveCGWindowIDs: [2])

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1), "CG 里没有了，出列")
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2), "CG 里还在，留着")
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 1), "别的进程不受影响")
    }

    func testRemoveDropsExactlyOneEntry() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)

        cache.remove(pid: 42, cgWindowID: 1)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2))
    }
}
