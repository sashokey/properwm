import XCTest
@testable import macos_dock_cc_v2

final class DragLandingPlanTests: XCTestCase {
    private let carrier = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAnchorCentreConvertsToCarrierPanelCoordinates() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 900, y: 400),
                                            fromScale: DragLandingPlan.carriedScale,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: carrier)
        XCTAssertEqual(flight?.to.x, 720)
        XCTAssertEqual(flight?.to.y, 947)
    }

    func testCarrierOriginIsSubtracted() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let slot = CGRect(x: 0, y: 1000, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: .zero,
                                            fromScale: 1,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: external)
        XCTAssertEqual(flight?.to.x, 20 - (-504))
        XCTAssertEqual(flight?.to.y, (982 + 1440) - 1027)
    }

    func testStartStateIsCarriedThrough() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 123, y: 456),
                                            fromScale: 0.9,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: carrier)
        XCTAssertEqual(flight?.from, CGPoint(x: 123, y: 456))
        XCTAssertEqual(flight?.fromScale, 0.9)
    }

    func testAlwaysLandsAtNativeScale() {
        for start in [DragLandingPlan.carriedScale, 0.9] {
            let flight = DragLandingPlan.flight(from: .zero, fromScale: start,
                                                anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                carrierScreenFrame: carrier)
            XCTAssertEqual(flight?.toScale, 1.0)
        }
    }

    func testNoAnchorMeansNoFlight() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: nil, carrierScreenFrame: carrier))
    }

    func testUnmeasuredAnchorIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: .zero, carrierScreenFrame: carrier))
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 10, y: 10, width: 0, height: 54),
                                            carrierScreenFrame: carrier))
    }

    func testEmptyCarrierFrameIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: .zero))
    }

    func testDurationGrowsWithDistanceAndIsClampedAtBothEnds() {
        XCTAssertEqual(DragLandingPlan.duration(travel: 0), DragLandingPlan.minimumDuration)
        XCTAssertEqual(DragLandingPlan.duration(travel: DragLandingPlan.referenceTravel),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        XCTAssertEqual(DragLandingPlan.duration(travel: 5000),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        XCTAssertEqual(DragLandingPlan.duration(travel: -10), DragLandingPlan.minimumDuration)
    }

    func testShortTravelIsMoreGenerousThanLinear() {
        let quarter = DragLandingPlan.referenceTravel / 4
        let linear = DragLandingPlan.minimumDuration
            + (DragLandingPlan.maximumFlightDuration - DragLandingPlan.minimumDuration) * 0.25
        XCTAssertGreaterThan(DragLandingPlan.duration(travel: quarter), linear)
    }

    func testFlightCarriesItsOwnDuration() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)
        let far = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                         anchorScreenRect: CGRect(x: 1200, y: 8, width: 40, height: 54),
                                         carrierScreenFrame: carrier)
        XCTAssertNotNil(near?.duration)
        XCTAssertLessThan(near!.duration, far!.duration)
    }

    func testOnlySubPixelTravelSkipsTheFlight() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = CGPoint(x: 720, y: 982 - 35)
        let subPixel = CGPoint(x: centre.x + 0.3, y: centre.y + 0.2)
        XCTAssertNil(DragLandingPlan.flight(from: subPixel, fromScale: 1,
                                            anchorScreenRect: slot, carrierScreenFrame: carrier))
        let jitter = CGPoint(x: centre.x + 4, y: centre.y + 3)
        XCTAssertNotNil(DragLandingPlan.flight(from: jitter, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    func testTravelBeyondTheThresholdStillFlies() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let away = CGPoint(x: 720 + DragLandingPlan.minimumTravel + 6, y: 982 - 35)
        XCTAssertNotNil(DragLandingPlan.flight(from: away, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    func testThresholdOnlyBlocksSubPixelTravel() {
        XCTAssertGreaterThan(DragLandingPlan.minimumTravel, 0)
        XCTAssertLessThan(DragLandingPlan.minimumTravel, 8)
    }

    func testCurveEndsAreFrozen() {
        XCTAssertEqual(DragLandingPlan.curve(travel: 0), DragLandingPlan.shortCurve)
        let long = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)
        XCTAssertEqual(DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel), long)
        XCTAssertEqual(DragLandingPlan.curve(travel: 5000), long)
        XCTAssertEqual(DragLandingPlan.curve, long)
    }

    func testShortCurveIsGentlerThanTheLongOne() {
        XCTAssertLessThan(DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y)
        XCTAssertLessThanOrEqual(DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y)
    }

    func testCurveInterpolatesBetweenTheEnds() {
        let mid = DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel / 4)
        let f = DragLandingPlan.travelFactor(DragLandingPlan.referenceTravel / 4)
        XCTAssertEqual(f, 0.5, accuracy: 0.0001)
        func between(_ v: Double, _ a: Double, _ b: Double) -> Bool { v >= min(a, b) && v <= max(a, b) }
        XCTAssertTrue(between(mid.c0x, DragLandingPlan.shortCurve.c0x, DragLandingPlan.curve.c0x))
        XCTAssertTrue(between(mid.c0y, DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y))
        XCTAssertTrue(between(mid.c1x, DragLandingPlan.shortCurve.c1x, DragLandingPlan.curve.c1x))
        XCTAssertTrue(between(mid.c1y, DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y))
        XCTAssertEqual(mid.c0y, DragLandingPlan.shortCurve.c0y
                       + (DragLandingPlan.curve.c0y - DragLandingPlan.shortCurve.c0y) * f, accuracy: 0.0001)
    }

    func testCurveProgressMatchesTheBezier() {
        let long = DragLandingPlan.curve, short = DragLandingPlan.shortCurve
        XCTAssertEqual(long.progress(at: 0), 0)
        XCTAssertEqual(long.progress(at: 1), 1)
        XCTAssertEqual(long.progress(at: -1), 0)
        XCTAssertEqual(long.progress(at: 2), 1)
        XCTAssertEqual(long.progress(at: 0.17), 0.61, accuracy: 0.03)
        XCTAssertEqual(short.progress(at: 0.5), 0.77, accuracy: 0.02)
        var previous = 0.0
        for i in 1...100 {
            let v = long.progress(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-9)
            previous = v
        }
        XCTAssertGreaterThan(long.progress(at: 0.3), short.progress(at: 0.3), "长途更抢")
    }

    func testFlightCarriesItsOwnCurve() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        let travel = hypot(near.to.x - near.from.x, near.to.y - near.from.y)
        XCTAssertEqual(near.curve, DragLandingPlan.curve(travel: travel))
        XCTAssertNotEqual(near.curve, DragLandingPlan.curve)   // 短途不是长途那条
    }

    func testReturnFlightLandsOpaque() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.toOpacity, 1)
    }

    func testRetargetIsRefusedNearTheDeadline() {
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: 0))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.duration))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: -1))
    }

    func testRetargetIsAllowedWhileThereIsRoomForAWholeFlight() {
        XCTAssertTrue(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.maximumDuration))
    }

    func testDeadlineLeavesRoomForAtLeastOneRetarget() {
        XCTAssertGreaterThan(DragLandingPlan.maximumDuration,
                             2 * (DragLandingPlan.duration + DragLandingPlan.settleMargin))
    }

    func testSlidingARetargetKeepsTheTimelineAndOnlyMovesTheDestination() {
        let carrier = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 500, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        let slid = flight.sliding(to: CGPoint(x: 480, y: 120), toScale: 0.5)
        XCTAssertEqual(slid.to, CGPoint(x: 480, y: 120))
        XCTAssertEqual(slid.toScale, 0.5)
        XCTAssertEqual(slid.from, flight.from)
        XCTAssertEqual(slid.fromScale, flight.fromScale)
        XCTAssertEqual(slid.duration, flight.duration)
        XCTAssertEqual(slid.curve, flight.curve)
        XCTAssertEqual(slid.toOpacity, flight.toOpacity)
    }

    func testHoldingFlightIsStationaryAndARealFlightIsNot() {
        let held = DragLandingPlan.holdingFlight(at: CGPoint(x: 500, y: 100), scale: 1)
        XCTAssertTrue(held.isStationary)
        XCTAssertEqual(held.from, held.to)
        XCTAssertEqual(held.toScale, DragLandingPlan.landedScale)
        XCTAssertEqual(held.toOpacity, 1)
        let carrier = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let real = DragLandingPlan.flight(from: CGPoint(x: 500, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        XCTAssertFalse(real.isStationary)
        XCTAssertFalse(held.sliding(to: real.to, toScale: real.toScale).isStationary)
    }

    func testLiftIsMuchShorterThanTheReturnFlight() {
        XCTAssertLessThan(DragLandingPlan.liftDuration, DragLandingPlan.minimumDuration / 2)
        XCTAssertGreaterThan(DragLandingPlan.liftDuration, 0)
    }

    func testDurationTableStaysInTheNativeBallpark() {
        XCTAssertGreaterThan(DragLandingPlan.minimumDuration, 0.15)
        XCTAssertLessThan(DragLandingPlan.minimumDuration, 0.45)
        XCTAssertGreaterThan(DragLandingPlan.maximumFlightDuration, DragLandingPlan.minimumDuration)
        XCTAssertLessThan(DragLandingPlan.maximumFlightDuration, 0.70)
    }

    func testFlightDurationOverrideRejectsAnythingMalformed() {
        for bad in ["", "320", "320,", ",500", "abc,500", "320,abc", "0,500", "-320,500", "500,320", "320,500,700"] {
            XCTAssertNil(DragLandingPlan.parseFlightDurations(bad), "「\(bad)」不该被接受")
        }
        let good = DragLandingPlan.parseFlightDurations("320,500")
        XCTAssertEqual(good?.minimum ?? 0, 0.32, accuracy: 0.0001)
        XCTAssertEqual(good?.maximum ?? 0, 0.50, accuracy: 0.0001)
        XCTAssertNotNil(DragLandingPlan.parseFlightDurations(" 400 , 400 "))
    }
}
