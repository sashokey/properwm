import CoreGraphics
import XCTest

/// CG 全表复用门控的纯决策锁：静态条件序、探针比对、杀开关旁路。
final class CGSnapshotReuseDecisionTests: XCTestCase {
    private typealias Decision = CGSnapshotReuseDecision

    private func input(
        reuseEnabled: Bool = true,
        hasCache: Bool = true,
        cachedCaptureFailed: Bool = false,
        cacheAge: TimeInterval = 0.5,
        generationMatches: Bool = true,
        hasAbsenceClock: Bool = false,
        hasPhantomCandidate: Bool = false,
        observerActive: Bool = true
    ) -> Decision.Input {
        Decision.Input(
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

    func testGatesBeforeProbe() {
        let cases: [(name: String, input: Decision.Input, expected: Decision.PreVerdict)] = [
            ("Reusable", input(), .probeThenCompare),
            ("Reuse disabled", input(reuseEnabled: false), .captureWithoutProbe),
            ("No cache", input(hasCache: false), .captureAndPrime(.noCache)),
            ("Failed capture", input(cachedCaptureFailed: true), .captureAndPrime(.cachedCaptureFailed)),
            ("At expiry", input(cacheAge: Decision.defaultMaxCacheAge), .captureAndPrime(.cacheExpired)),
            ("Negative age", input(cacheAge: -1), .captureAndPrime(.cacheExpired)),
            ("Event generation changed", input(generationMatches: false), .captureAndPrime(.eventSinceCache)),
            ("Absence clock running", input(hasAbsenceClock: true), .captureAndPrime(.absenceClockRunning)),
            ("Phantom candidate", input(hasPhantomCandidate: true), .captureAndPrime(.phantomCandidate)),
            ("Inactive observer", input(observerActive: false), .captureAndPrime(.observerInactive)),
        ]

        for (name, input, expected) in cases {
            XCTAssertEqual(Decision.preVerdict(input), expected, name)
        }
    }

    func testProbeComparisonUsesTheWholeIDSet() {
        let cachedProbe: Set<CGWindowID> = [1, 2, 3]
        XCTAssertEqual(Decision.probeVerdict(probe: [1, 2, 3], cachedProbe: cachedProbe), .reuse)

        let changedProbes: [Set<CGWindowID>] = [[1, 2], [1, 2, 4]]
        for probe in changedProbes {
            XCTAssertEqual(Decision.probeVerdict(probe: probe, cachedProbe: cachedProbe), .captureAndPrime(.probeChanged))
        }
    }

    func testCachedLayerVetoAppliesOnlyWhenAXListsACachedBelowLayerID() {
        let cases: [(belowNormalIDs: Set<CGWindowID>, veto: Bool)] = [
            ([2, 9], true),
            ([9], false),
            ([], false),
        ]
        for (belowNormalIDs, veto) in cases {
            XCTAssertEqual(Decision.cachedLayerVetoApplies(axWindowIDs: [1, 2], cachedBelowNormalLayerIDs: belowNormalIDs), veto)
        }
    }
}
