import CoreGraphics
import Foundation

struct WindowFrameMatchPolicy {
    static let tolerance: CGFloat = 24

    static func integralComponents(for bounds: CGRect) -> [Int]? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let values = [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height]
        let components = values.compactMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
        guard components.count == values.count,
              bounds.maxX.isFinite, bounds.maxY.isFinite,
              Int(exactly: bounds.maxX.rounded()) != nil,
              Int(exactly: bounds.maxY.rounded()) != nil else { return nil }
        return components
    }

    static func isValid(_ bounds: CGRect) -> Bool {
        integralComponents(for: bounds) != nil
    }

    static func areClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = Self.tolerance
    ) -> Bool {
        isValid(lhs) && isValid(rhs) && tolerance.isFinite && tolerance >= 0
            && abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func score(_ lhs: CGRect, _ rhs: CGRect) -> Int {
        guard isValid(lhs), isValid(rhs) else { return .max }
        let distance = abs(lhs.origin.x - rhs.origin.x)
                + abs(lhs.origin.y - rhs.origin.y)
                + abs(lhs.width - rhs.width)
                + abs(lhs.height - rhs.height)
        return Int(exactly: distance.rounded(.towardZero)) ?? .max
    }

    static func signature(for bounds: CGRect?) -> String {
        guard let bounds, let values = integralComponents(for: bounds) else { return "no-frame" }
        return values.map(String.init).joined(separator: ":")
    }
}
