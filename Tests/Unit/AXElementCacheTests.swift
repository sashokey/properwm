import ApplicationServices
import CoreGraphics
import XCTest

/// AX 元素旁路缓存的存取与失效规则。
///
/// 这条规则一旦写错有两个方向的坏结果，方向相反、都很难看出来：
/// - 留下指向已销毁窗口的陈旧元素 → cgWindowID 复用后可能操作到**别的窗口**；
/// - 把最小化后离开 `AXWindows` 的窗口误删 → 缓存在最该发挥作用的时刻恰好是空的，白建。
final class AXElementCacheTests: XCTestCase {
    func testElementIdentitySurvivesTransferFromABackgroundTask() async {
        let key = await Task.detached {
            AXElementKey(e: AXUIElementCreateApplication(getpid()))
        }.value
        let returned = await Task.detached { key }.value

        XCTAssertEqual(key, returned)
        XCTAssertEqual(key.hashValue, returned.hashValue)
        XCTAssertEqual(CFGetTypeID(returned.e), AXUIElementGetTypeID())
    }

    func testWindowStillInCGListSurvivesEvenWhenAXNoLongerReportsIt() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 7, element: element)
        cache.retain(pid: 42, liveCGWindowIDs: [7])
        XCTAssertEqual(cache.element(pid: 42, cgWindowID: 7).map { CFEqual($0, element) }, true)
    }

    func testSuccessfulEmptyLiveListExpiresAllHandlesForOnlyThatProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 43, cgWindowID: 3, element: element)
        cache.retain(pid: 42, liveCGWindowIDs: [])
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 1))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 2))
        XCTAssertNotNil(cache.element(pid: 43, cgWindowID: 3))
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
