import AppKit
import SwiftUI

struct StripHoverFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ChipFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
final class StripFrameBox {
    var chipFrames: [String: CGRect] = [:]
    var stripHoverFrames: [String: CGRect] = [:]
    var stripRootScreenRect: CGRect = .zero
}
