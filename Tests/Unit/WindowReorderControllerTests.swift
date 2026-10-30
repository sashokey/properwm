import AppKit
import Combine
import XCTest

@MainActor
final class WindowReorderControllerTests: XCTestCase {

    private var controller: DragController!
    private let outsideZone = CGPoint(x: 500, y: 500)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        controller = DragController(screensProvider: { NSScreen.screens })
    }

    override func tearDown() {
        controller.cancelDrag()   // 幂等收尾，防面板/监视器泄漏到下个用例
        super.tearDown()
    }

    private func payload(_ source: DragSource, _ bid: String) -> DragPayload {
        DragPayload(source: source, id: bid, bundleID: bid, item: nil, visualKind: .stripChip)
    }

    private func stubSnapshot(side: Int = 1) -> CarrierSnapshot {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 4 * side,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CarrierSnapshot(image: context.makeImage()!,
                               size: CGSize(width: side, height: side),
                               contentSize: CGSize(width: side, height: side),
                               scale: 1)
    }

    private func begin(_ source: DragSource, _ bid: String, at point: CGPoint, surface: String? = nil) {
        controller.beginDrag(payload: payload(source, bid), stripSurfaceID: surface, startScreenLocation: point,
                             grabOffset: .zero, sourceScreenRect: .zero, pose: .resting,
                             snapshot: stubSnapshot())
    }

    private func settle(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
        let until = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    func testSlotStaysFilledUntilTheCarrierHasHadAFrame() {
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload, "拖动本身立刻开始")
        XCTAssertNil(controller.hiddenSlotPayload, "但这一轮条上那格还不能空")
        XCTAssertTrue(controller.hoverFrozen, "这几帧悬停原地冻结，卡不能变形")

        let nextTurn = expectation(description: "下一轮 run loop")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertNil(controller.hiddenSlotPayload, "下一轮 run loop 仍不放行")

        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "两个显示帧后才空出来")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed, "藏卡之后悬停改为压制")
    }

    func testPreparedCandidateArmsImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: .zero, sourceScreenRect: slot, pose: .resting,
                             snapshot: nil)   // 有候选就不该再拍：这里传 nil 也必须能起拖
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "当轮就藏卡")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed)
    }

    func testMismatchedCandidateIsIgnored() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "other", sourceScreenRect: slot, snapshot: stubSnapshot())
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertNil(controller.hiddenSlotPayload, "没有匹配的候选 → 仍要先压着卡")
    }

    func testClearedCandidateDoesNotArmImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.clearCandidate(payloadID: "app")
        begin(.strip, "app", at: outsideZone)
        XCTAssertNil(controller.hiddenSlotPayload)
    }

    func testLandingSideIsNotGatedTheSameWay() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertNotNil(controller.hiddenSlotPayload)

        controller.endDrag()
        XCTAssertEqual(controller.landing?.flight.isStationary, true, "没锚点先原地按住，不瞬时收尾")
        waitUntil(1) { controller.landing == nil }
        XCTAssertNil(controller.landing, "锚点始终没来 → 按住期一到就落定")
        XCTAssertNil(controller.hiddenSlotPayload, "不飞的收尾也要立刻让卡显形")
        XCTAssertTrue(controller.isCarrying, "但载体还没撤，悬停仍要压着")
    }

    func testHoverStaysHeldAfterLandingUntilThePointerMoves() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.endDrag()
        waitUntil { controller.landing == nil }
        XCTAssertEqual(controller.hoverHoldPayload?.bundleID, "app")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app")
        waitUntil { !controller.isCarrying }
        XCTAssertFalse(controller.isCarrying, "载体已经撤了")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "但指针没动，它自己仍按住")
        waitUntil(DragLandingPlan.hoverHoldMaximum + 1) { controller.hoverHoldPayload == nil }
        XCTAssertNil(controller.hoverHoldPayload)
        XCTAssertNil(controller.hoverExemptPayload)
    }

    func testOnlyTheFlyingCardIsExemptDuringTheReturnFlight() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "needs a refreshing display; skipped on CI")
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertTrue(controller.hoverSuppressed, "拎着的时候整条不判悬停")

        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54),
                                    owner: .strip)
        controller.endDrag()
        XCTAssertNotNil(controller.landing, "起飞了")
        XCTAssertFalse(controller.hoverSuppressed, "飞行期不再整条压制——别的卡要能悬停")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "只豁免正在飞的那一张")
    }

    private func flyBack(from point: CGPoint) {
        begin(.strip, "app", at: point)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.setLandingAnchor(CGRect(x: point.x + 200, y: point.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
    }

    func testRegrabDuringLandingContinuesTheDragWithoutAGap() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing, "有锚点、位移够 → 起飞")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "飞行中卡槽空着")

        XCTAssertFalse(controller.regrabLanding(at: CGPoint(x: outsideZone.x - 900, y: outsideZone.y - 900)))
        XCTAssertNotNil(controller.landing)

        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.landing, "飞行结束")
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app", "变成新拖动")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "卡槽连续空着")
        XCTAssertTrue(controller.isCarrying)
        XCTAssertFalse(controller.hoverFrozen, "重抓的载体早就抬起了，不需要起拖那几帧的冻结")
        XCTAssertTrue(controller.hoverSuppressed)
        XCTAssertNil(controller.hoverHoldPayload)

        controller.endDrag()
        XCTAssertNil(controller.draggingPayload)
    }

    func testBeginDragOfTheSameCardDuringLandingRegrabs() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "app", at: CGPoint(x: outsideZone.x + 30, y: outsideZone.y))
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "当轮就空着，没有起拖那两帧的门控")
        XCTAssertTrue(controller.carrierArmed)
    }

    func testBeginDragOfAnotherCardDuringLandingAbortsTheFlight() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "other", at: outsideZone)
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "other")
    }

    func testRegrabThenReleaseWithoutMovingIsAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertEqual(clicks.map(\.bundleID), ["app"])
        XCTAssertNotNil(controller.landing, "点完图标接着飞回卡槽")
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        XCTAssertNil(controller.draggingPayload)
    }

    func testOrdinaryReleaseIsNotAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(clicks.isEmpty)
    }

    func testRegrabAfterTheFlightIsRefused() {
        flyBack(from: outsideZone)
        waitUntil(DragLandingPlan.maximumDuration + 1) { controller.landing == nil }
        XCTAssertNil(controller.landing)
        XCTAssertFalse(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.draggingPayload)
    }

}

extension WindowReorderControllerTests {

    func testCancellationClearsSurfaceAndCarrierState() {
        begin(.strip, "window", at: outsideZone, surface: "display-A")
        XCTAssertEqual(controller.activeStripSurfaceID, "display-A")
        controller.cancelDrag()
        XCTAssertNil(controller.activeStripSurfaceID)
        XCTAssertNil(controller.draggingPayload)
        XCTAssertNil(controller.landing)
        XCTAssertNil(controller.hiddenSlotPayload)
        waitUntil { !controller.isCarrying }
        XCTAssertFalse(controller.isCarrying)
    }

    func testMissingLiveAnchorReturnsToLastKnownWindowSlot() {
        begin(.strip, "window", at: outsideZone, surface: "display-A")
        controller.setLandingAnchor(CGRect(x: 200, y: 20, width: 40, height: 54), owner: .strip)
        controller.setLandingAnchor(nil, owner: .strip)
        controller.endDrag()
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        XCTAssertEqual(controller.landing?.flight.isStationary, false)
    }

    func testOldCancellationCannotRetireANewerDrag() {
        begin(.strip, "first-window", at: outsideZone, surface: "display-A")
        controller.cancelDrag()
        begin(.strip, "second-window", at: outsideZone, surface: "display-B")
        let nextTurn = expectation(description: "Cancellation handoff completed")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertEqual(controller.draggingPayload?.id, "second-window")
        XCTAssertEqual(controller.activeStripSurfaceID, "display-B")
        XCTAssertTrue(controller.isCarrying)
    }
}
