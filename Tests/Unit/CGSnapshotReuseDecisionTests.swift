import CoreGraphics
import XCTest

/// CG 全表复用门控的纯决策锁：静态条件序、探针比对、杀开关旁路。
final class CGSnapshotReuseDecisionTests: XCTestCase {
    private func input(
        reuseEnabled: Bool = true,
        hasCache: Bool = true,
        cachedCaptureFailed: Bool = false,
        cacheAge: TimeInterval = 0.5,
        generationMatches: Bool = true,
        hasAbsenceClock: Bool = false,
        hasPhantomCandidate: Bool = false,
        observerActive: Bool = true
    ) -> CGSnapshotReuseDecision.Input {
        CGSnapshotReuseDecision.Input(
            reuseEnabled: reuseEnabled,
            hasCache: hasCache,
            cachedCaptureFailed: cachedCaptureFailed,
            cacheAge: cacheAge,
            generationMatches: generationMatches,
            hasAbsenceClock: hasAbsenceClock,
            hasPhantomCandidate: hasPhantomCandidate,
            observerActive: observerActive
        )
    }

    func testAllConditionsHeldProceedsToProbe() {
        XCTAssertEqual(CGSnapshotReuseDecision.preVerdict(input()), .probeThenCompare)
    }

    func testKillSwitchSkipsProbeEntirely() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(reuseEnabled: false)),
            .captureWithoutProbe
        )
    }

    func testNoCacheCapturesAndPrimes() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(hasCache: false)),
            .captureAndPrime(.noCache)
        )
    }

    func testFailedCachedCaptureNeverReused() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(cachedCaptureFailed: true)),
            .captureAndPrime(.cachedCaptureFailed)
        )
    }

    func testExpiredCacheCaptures() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(
                input(cacheAge: CGSnapshotReuseDecision.defaultMaxCacheAge)
            ),
            .captureAndPrime(.cacheExpired)
        )
    }

    func testNegativeAgeIsExpiredNotEternal() {
        // 单调钟异常（如注入的测试时钟回拨）按过期处理，不能反向放大复用窗口。
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(cacheAge: -1)),
            .captureAndPrime(.cacheExpired)
        )
    }

    func testEventGenerationMismatchCaptures() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(generationMatches: false)),
            .captureAndPrime(.eventSinceCache)
        )
    }

    func testAbsenceClockForcesCapture() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(hasAbsenceClock: true)),
            .captureAndPrime(.absenceClockRunning)
        )
    }

    func testPhantomCandidateForcesCapture() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(hasPhantomCandidate: true)),
            .captureAndPrime(.phantomCandidate)
        )
    }

    func testInactiveObserverForcesCapture() {
        // 观察者不在 → AX 事件到不了 → 代数判据失效，必须现拍。
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(observerActive: false)),
            .captureAndPrime(.observerInactive)
        )
    }

    func testProbeMatchReuses() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.probeVerdict(probe: [1, 2, 3], cachedProbe: [1, 2, 3]),
            .reuse
        )
    }

    func testProbeChangeCaptures() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.probeVerdict(probe: [1, 2], cachedProbe: [1, 2, 3]),
            .captureAndPrime(.probeChanged)
        )
        XCTAssertEqual(
            CGSnapshotReuseDecision.probeVerdict(probe: [1, 2, 4], cachedProbe: [1, 2, 3]),
            .captureAndPrime(.probeChanged)
        )
    }

    func testCachedLayerVetoAppliesOnlyWhenAXListsACachedBelowLayerID() {
        XCTAssertTrue(CGSnapshotReuseDecision.cachedLayerVetoApplies(
            axWindowIDs: [1, 2], cachedBelowNormalLayerIDs: [2, 9]
        ))
        XCTAssertFalse(CGSnapshotReuseDecision.cachedLayerVetoApplies(
            axWindowIDs: [1, 2], cachedBelowNormalLayerIDs: [9]
        ))
        XCTAssertFalse(CGSnapshotReuseDecision.cachedLayerVetoApplies(
            axWindowIDs: [1, 2], cachedBelowNormalLayerIDs: []
        ))
    }
}
