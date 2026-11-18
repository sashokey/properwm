import CoreGraphics
import XCTest

/// Verdict matrix of the absence fallback: only a dead element on a current / no Space, confirmed
/// 2–10s later for the same cgID and subscription instance, releases.
final class AbsentSeatReleaseDecisionTests: XCTestCase {
    private func input(
        element: AbsentSeatReleaseDecision.ElementState = .dead,
        spaces: AbsentSeatReleaseDecision.SpaceClass = .onlyCurrent,
        firstHiddenAt: TimeInterval? = nil,
        firstCgID: CGWindowID = 20,
        firstInstance: UInt64 = 7,
        matches: Bool = true
    ) -> AbsentSeatReleaseDecision.Input {
        AbsentSeatReleaseDecision.Input(
            evidenceMatchesSeat: matches,
            element: element,
            spaces: spaces,
            firstHidden: firstHiddenAt.map {
                AbsentSeatProbeState.FirstHiddenMark(uptime: $0, cgWindowID: firstCgID, instanceID: firstInstance)
            },
            cgWindowID: 20,
            instanceID: 7,
            now: 100
        )
    }

    func testFirstHiddenProbeOnlyMarks() {
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input()), .markFirst)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(spaces: .none)), .markFirst)
    }

    func testConfirmationWindowIsTwoToTenSeconds() {
        let cases: [(firstHiddenAt: TimeInterval, verdict: AbsentSeatReleaseDecision.Verdict)] = [
            (98.5, .holdMark),
            (98, .release),
            (90, .release),
            (89.9, .markFirst),
        ]
        for (firstHiddenAt, verdict) in cases {
            XCTAssertEqual(
                AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: firstHiddenAt)),
                verdict,
                "First hidden at \(firstHiddenAt)"
            )
        }
    }

    func testMarkForAnotherCgIDOrInstanceDoesNotConfirm() {
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 97, firstCgID: 21)), .markFirst)
        XCTAssertEqual(AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 97, firstInstance: 9)), .markFirst)
    }

    /// The other-Space case: a live element answering `min == false` must never count as hidden.
    func testLiveElementIsNeverHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(element: .alive(minimized: false), firstHiddenAt: 97)),
            .notHidden(.elementAlive)
        )
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(element: .alive(minimized: true))),
            .notHidden(.elementAlive)
        )
    }

    func testUnknownElementOrSpaceIsNotHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(element: .unknown(errorCode: -25204), firstHiddenAt: 97)),
            .notHidden(.elementUnknown)
        )
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(spaces: .unknown, firstHiddenAt: 97)),
            .notHidden(.spaceUnknown)
        )
    }

    func testDeadElementOnAnotherSpaceIsNotHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(spaces: .includesNonCurrent, firstHiddenAt: 97)),
            .notHidden(.onNonCurrentSpace)
        )
    }

    func testMismatchedEvidenceIsNotHidden() {
        XCTAssertEqual(
            AbsentSeatReleaseDecision.verdict(input(firstHiddenAt: 97, matches: false)),
            .notHidden(.evidenceMismatch)
        )
    }

    func testSpaceClassification() {
        typealias SpaceClass = AbsentSeatReleaseDecision.SpaceClass
        let cases: [(window: [Int]?, current: Set<Int>?, expected: SpaceClass)] = [
            (nil, [1], .unknown),
            ([1], nil, .unknown),
            ([], [1], .none),
            ([1, 14255], [1, 14255], .onlyCurrent),
            ([6013], [1, 14255], .includesNonCurrent),
            ([1, 6013], [1], .includesNonCurrent),
        ]
        for (window, current, expected) in cases {
            XCTAssertEqual(
                SpaceClass.classify(windowSpaceIDs: window, currentSpaceIDs: current),
                expected,
                "Window spaces \(String(describing: window)), current spaces \(String(describing: current))"
            )
        }
    }

    func testBackoffSchedule() {
        let cases: [(dispatches: Int, delay: TimeInterval)] = [(1, 2), (2, 5), (3, 15), (4, 60), (40, 60)]
        for (dispatches, delay) in cases {
            XCTAssertEqual(AbsentSeatReleaseDecision.backoff(afterDispatch: dispatches), delay, "Dispatch \(dispatches)")
        }
    }
}
