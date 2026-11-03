import CoreGraphics
import XCTest

final class TabFoldDecisionTests: XCTestCase {
    private func seat(cg: CGWindowID, former: Set<CGWindowID> = []) -> TabFoldDecision.PlacedSeat {
        TabFoldDecision.PlacedSeat(activeCgID: cg, formerCgIDs: former)
    }

    private func verdict(cg: CGWindowID = 240522, minimized: Bool = true, shadow: Bool = false,
                         placed: [TabFoldDecision.PlacedSeat]) -> TabFoldDecision.Verdict {
        TabFoldDecision.verdict(candidateCgID: cg, candidateIsMinimized: minimized,
                                candidateIsKnownShadow: shadow, placedSeats: placed)
    }

    func testUnknownMinimizedCandidateCreatesIndependentSeatBesideOneSeat() {
        XCTAssertEqual(verdict(placed: [seat(cg: 249469)]), .newSeat)
    }

    func testUnknownMinimizedCandidateCreatesIndependentSeatBesideMultipleSeats() {
        XCTAssertEqual(verdict(placed: [seat(cg: 249469), seat(cg: 253982)]), .newSeat)
    }

    func testUnknownMinimizedCandidateCreatesSeatWithoutPlacedSeats() {
        XCTAssertEqual(verdict(placed: []), .newSeat)
    }

    func testKnownMinimizedMemberFoldsIntoItsOwner() {
        XCTAssertEqual(verdict(placed: [seat(cg: 249469, former: [240522])]),
                       .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    func testMembershipSelectsItsOwnerAmongIndependentSeats() {
        XCTAssertEqual(verdict(placed: [seat(cg: 249469), seat(cg: 253982, former: [240522])]),
                       .fold(ownerActiveCgID: 253982, reason: .membership))
    }

    func testNonMinimizedFormerMemberGetsIndependentSeat() {
        XCTAssertEqual(verdict(minimized: false, placed: [seat(cg: 249469, former: [240522])]), .newSeat)
    }

    func testAmbiguousMembershipFoldsWithoutLearning() {
        XCTAssertEqual(verdict(placed: [seat(cg: 249469, former: [240522]), seat(cg: 253982, former: [240522])]),
                       .fold(ownerActiveCgID: nil, reason: .membership))
    }

    func testKnownShadowFoldsIntoSinglePlacedSeat() {
        XCTAssertEqual(verdict(shadow: true, placed: [seat(cg: 249469)]),
                       .fold(ownerActiveCgID: 249469, reason: .shadowPool))
    }

    func testNonMinimizedKnownShadowGetsIndependentSeat() {
        XCTAssertEqual(verdict(minimized: false, shadow: true, placed: [seat(cg: 249469)]), .newSeat)
    }

    func testKnownShadowWithNoPlacedSeatsCreatesRepresentativeSeat() {
        XCTAssertEqual(verdict(shadow: true, placed: []), .newSeat)
    }

    func testKnownShadowWithMultipleSeatsFoldsWithoutLearning() {
        XCTAssertEqual(verdict(shadow: true, placed: [seat(cg: 249469), seat(cg: 253982)]),
                       .fold(ownerActiveCgID: nil, reason: .shadowPool))
    }

    func testMembershipWinsOverShadowPool() {
        XCTAssertEqual(verdict(shadow: true, placed: [seat(cg: 249469, former: [240522]), seat(cg: 253982)]),
                       .fold(ownerActiveCgID: 249469, reason: .membership))
    }
}

/// 幽灵座位自愈纯判定（PhantomSeatDecision）：五门槛全过才释放，宁可不愈不误删。
/// 幽灵座位 = 折叠失手时从 min=true 爆发候选裂出来的多余座位（典型：dock 启动时窗口已最小化，
/// seed 无历史无影子池），还原窗口后它离开 AX、仍在 CG，被 min 保留规则永久扣住。
final class PhantomSeatDecisionTests: XCTestCase {

    private func release(
        everSeenVisible: Bool = false,
        axAbsentFor: TimeInterval = 12,
        cgStillPresent: Bool = true,
        axReadSawWindows: Bool = true,
        siblings: Int = 1
    ) -> Bool {
        PhantomSeatDecision.shouldRelease(
            everSeenVisible: everSeenVisible, axAbsentFor: axAbsentFor, threshold: 10,
            cgStillPresent: cgStillPresent, axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: siblings
        )
    }

    func testReleasesWhenAllGatesPass() {
        XCTAssertTrue(release())
    }

    func testEverSeenVisibleProtectsRealWindow() {
        // Safari 式真窗口：可见过 → 最小化后整个离开 AX 也永不自愈（最小化不丢卡是硬护栏）
        XCTAssertFalse(release(everSeenVisible: true))
    }

    func testUnderThresholdDoesNotRelease() {
        // AX 偶发漏读一两轮不算幽灵
        XCTAssertFalse(release(axAbsentFor: 9.9))
    }

    func testHungAppDoesNotRelease() {
        // 本轮 AX 一个窗口都没读到（app 挂死）→ 按兵不动
        XCTAssertFalse(release(axReadSawWindows: false))
    }

    func testLoneSeatNeverReleases() {
        // 孤座位永不自愈：app 仅有的卡不能被自愈删掉
        XCTAssertFalse(release(siblings: 0))
    }

    func testCgGoneIsNotHealingBusiness() {
        // 出了 CG 是真关闭，走既有删除路径，自愈不管
        XCTAssertFalse(release(cgStillPresent: false))
    }

    func testEvaluationExportsAllFailedGates() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: true,
            axAbsentFor: 9.9,
            threshold: 10,
            cgStillPresent: false,
            axReadSawWindows: false,
            axPresentSiblingCount: 0
        )

        XCTAssertFalse(evaluation.shouldRelease)
        XCTAssertEqual(evaluation.holdReasons, [
            .everSeenVisible,
            .absenceGraceNotElapsed,
            .cgMissing,
            .noEligibleWindows,
            .noAXPresentSibling,
        ])
    }

    func testEvaluationExportsEachFailedGate() {
        let cases: [(PhantomSeatDecision.HoldReason, PhantomSeatDecision.Evaluation)] = [
            (.everSeenVisible, PhantomSeatDecision.evaluate(
                everSeenVisible: true, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.absenceGraceNotElapsed, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 9.9, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.cgMissing, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: false, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.noEligibleWindows, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: false, axPresentSiblingCount: 1
            )),
            (.noAXPresentSibling, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 0
            )),
        ]

        for (reason, evaluation) in cases {
            XCTAssertFalse(evaluation.shouldRelease)
            XCTAssertEqual(evaluation.holdReasons, [reason])
        }
    }

    func testEvaluationHasNoHoldReasonsWhenAllGatesPass() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: false,
            axAbsentFor: 10,
            threshold: 10,
            cgStillPresent: true,
            axReadSawWindows: true,
            axPresentSiblingCount: 1
        )

        XCTAssertTrue(evaluation.shouldRelease)
        XCTAssertTrue(evaluation.holdReasons.isEmpty)
    }
}

/// Pass A「并入标签」纯决策层（TabMergeDecision）。
/// 背景（2026-09-12 访达实测）：「合并所有窗口」/ 把标签拖进别的窗后，原窗成为 order-out 后台标签——
/// 离开 AX、仍在 CG、onscreen=false、CG bounds 被改成所属窗口的 frame。旧路径无条件保座位 → 一扇窗
/// 两张卡，随后同 frame 两个老座位让切标签顶替失效，每切一次再裂一张。
final class TabMergeDecisionTests: XCTestCase {

    private func fk(_ b: CGRect?) -> String? {
        guard let b else { return nil }
        return "\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    private func sibling(cg: CGWindowID, bounds: CGRect?, min: Bool = false) -> TabMergeDecision.AXPresentSeat {
        TabMergeDecision.AXPresentSeat(activeCgID: cg, bounds: bounds, isMinimized: min)
    }

    private let mergedFrame = CGRect(x: 297, y: 340, width: 1227, height: 504)
    private let oldFrame = CGRect(x: 268, y: 311, width: 1227, height: 504)

    func testMergedTabReleasesAndLearnsOwner() {
        // 实测形态：座位存的 AX 帧还是旧窗位置，CG bounds 已跟着所属窗走；兄弟座位 AX 在场同 frame。
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testOnScreenCandidateIsNeverReleased() {
        // 真可见窗口的一次 AX 漏读：CG 说它在屏上 → 保座位，哪怕有同 frame 的兄弟（两窗重叠是合法场景）。
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: true, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testNoCoFramedVisibleSiblingRetains() {
        // 离屏 + 没有同 frame 的可见兄弟：可能是关窗后赖在 CG（走 tombstone）或别的，不在这里判。
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: oldFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testMinimizedSiblingDoesNotOwn() {
        // 同 frame 的兄弟自己是 min=true（最小化爆发中的标签）→ 不算可见归属，保守保座位。
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame, min: true)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testAmbiguousOwnersReleaseWithoutLearning() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 1, bounds: mergedFrame), sibling(cg: 2, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: nil))
    }

    func testFallsBackToSeatBoundsWhenCGHasNoRect() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testNoBoundsAtAllRetains() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }
}
