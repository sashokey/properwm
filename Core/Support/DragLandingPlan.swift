import CoreGraphics
import Foundation

struct DragLandingFlight: Equatable {
    let from: CGPoint
    let to: CGPoint
    let fromScale: CGFloat
    let toScale: CGFloat
    let duration: TimeInterval
    let curve: DragLandingCurve
    var toOpacity: Float = 1

    func sliding(to newTo: CGPoint, toScale newToScale: CGFloat) -> DragLandingFlight {
        DragLandingFlight(from: from, to: newTo, fromScale: fromScale, toScale: newToScale,
                          duration: duration, curve: curve, toOpacity: toOpacity)
    }

    var isStationary: Bool {
        hypot(to.x - from.x, to.y - from.y) < DragLandingPlan.minimumTravel
    }
}

struct DragLandingCurve: Equatable {
    let c0x: Double
    let c0y: Double
    let c1x: Double
    let c1y: Double

    func progress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<48 {
            let x = Self.bezier(s, c0x, c1x)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return Self.bezier(s, c0y, c1y)
    }

    private static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }
}

enum DragLandingPlan {
    static let minimumDuration: TimeInterval = DragLandingSwitches.flightDurations?.minimum ?? 0.32
    static let maximumFlightDuration: TimeInterval = DragLandingSwitches.flightDurations?.maximum ?? 0.50
    static let referenceTravel: CGFloat = 300

    static let minimumTravel: CGFloat = 1

    static let duration: TimeInterval = 0.26

    static func duration(travel: CGFloat) -> TimeInterval {
        minimumDuration + (maximumFlightDuration - minimumDuration) * travelFactor(travel)
    }

    static func travelFactor(_ travel: CGFloat) -> Double {
        min(1, max(0, Double(travel) / Double(referenceTravel))).squareRoot()
    }

    static func curve(travel: CGFloat) -> DragLandingCurve {
        let f = travelFactor(travel)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return DragLandingCurve(c0x: mix(shortCurve.c0x, curve.c0x),
                                c0y: mix(shortCurve.c0y, curve.c0y),
                                c1x: mix(shortCurve.c1x, curve.c1x),
                                c1y: mix(shortCurve.c1y, curve.c1y))
    }

    static let shortCurve = DragLandingCurve(c0x: 0.25, c0y: 0.46, c1x: 0.45, c1y: 0.94)

    static func parseFlightDurations(_ raw: String) -> (minimum: TimeInterval, maximum: TimeInterval)? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lo = parts[0], let hi = parts[1],
              lo > 0, hi > 0, lo <= hi else { return nil }
        return (lo / 1000, hi / 1000)
    }

    static let settleMargin: TimeInterval = 0.03

    static let maximumDuration: TimeInterval = 2.00

    static func allowsRetarget(remainingBeforeDeadline: TimeInterval,
                               flightDuration: TimeInterval = duration) -> Bool {
        remainingBeforeDeadline > flightDuration + settleMargin
    }

    static let curve = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)

    static let liftDuration: TimeInterval = 0.12

    static let liftDelay: TimeInterval = 0.034

    static let pickUpSettle: TimeInterval = 0.034

    static let landingSettle: TimeInterval = 0.034

    static let candidateOpacity: Float = 0.01

    static let regrabClickSlop: CGFloat = 8

    static let hoverHoldMaximum: TimeInterval = 3.0

    static let stateChangeDuration: TimeInterval = 0.12

    static let carriedScale: CGFloat = 1.0
    static let landedScale: CGFloat = 1.0

    static func holdingFlight(at point: CGPoint, scale: CGFloat) -> DragLandingFlight {
        DragLandingFlight(from: point, to: point, fromScale: scale, toScale: landedScale,
                          duration: minimumDuration, curve: shortCurve)
    }

    static func flight(from: CGPoint,
                       fromScale: CGFloat,
                       anchorScreenRect: CGRect?,
                       carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = anchorScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        let travel = hypot(to.x - from.x, to.y - from.y)
        guard travel >= minimumTravel else { return nil }
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: landedScale,
                                 duration: duration(travel: travel),
                                 curve: curve(travel: travel))
    }
}

enum DragLandingSwitches {
    static let enabled = DebugSwitch.dragLanding.isEnabled(in: ProcessInfo.processInfo.environment)

    static let flightDurations: (minimum: TimeInterval, maximum: TimeInterval)? =
        DebugSwitch.dragFlightMs.value(in: ProcessInfo.processInfo.environment)
            .flatMap(DragLandingPlan.parseFlightDurations)
}
