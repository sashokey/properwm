import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

final class ProcessGenerationCacheTests: XCTestCase {
    func testCacheHasAHardCapacityAcrossProcessChurn() {
        let cache = ProcessGenerationCache<Int>(capacity: 4, startTime: { _ in timeval(tv_sec: 1, tv_usec: 0) })
        for id in 1...100 { cache.remember(id, for: pid_t(id)) }
        XCTAssertEqual(cache.countForTesting, 4)
        XCTAssertNil(cache.value(for: 1))
        XCTAssertEqual(cache.value(for: 100), 100)
    }

    func testDeadProcessesArePrunedBeforeNewEntriesAreAdded() {
        let live = Mutex<Set<pid_t>>([1, 2])
        let cache = ProcessGenerationCache<Int>(startTime: { pid in
            live.withLock { $0.contains(pid) ? timeval(tv_sec: 1, tv_usec: 0) : nil }
        })
        cache.remember(1, for: 1)
        live.withLock { $0.remove(1) }
        cache.remember(2, for: 2)
        XCTAssertEqual(cache.countForTesting, 1)
        live.withLock { $0.remove(2) }
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.countForTesting, 0)
    }
}
