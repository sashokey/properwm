import CoreGraphics
import Foundation

enum TaskbarMetrics {
    static let height: CGFloat = 32
    static let leadingInset: CGFloat = 10
    static let trailingInset: CGFloat = 10
    static let buttonTop: CGFloat = 2
    static let buttonHeight: CGFloat = 28
    static let buttonSpacing: CGFloat = 2
    static let buttonCornerRadius: CGFloat = 4
    static let minimumCompressedButtonWidth: CGFloat = 74
    static let maximumButtonWidth: CGFloat = 164
    static let iconSize: CGFloat = 16
    static let iconInset: CGFloat = 6
    static let labelInset: CGFloat = 28
    static let labelTrailingInset: CGFloat = 8
    static let fontSize: CGFloat = 12
    static let overflowWidth: CGFloat = 32
    static let windowListWidth: CGFloat = 216
    static let windowListRowHeight: CGFloat = 40
    static let popupGap: CGFloat = 13

    static func panelFrame(on screen: CGRect) -> CGRect {
        CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: height)
    }

    static func buttonWidth(textWidth: CGFloat) -> CGFloat {
        guard textWidth.isFinite else { return minimumCompressedButtonWidth }
        return min(maximumButtonWidth, ceil(max(0, textWidth)) + labelInset + labelTrailingInset)
    }
}

struct TaskbarLayoutWindow: Equatable {
    let id: String
    let desiredWidth: CGFloat
}

struct TaskbarLayoutGroup: Equatable {
    let id: String
    let desiredWidth: CGFloat
    let windows: [TaskbarLayoutWindow]
}

struct TaskbarButtonLayout: Equatable {
    let id: String
    let groupID: String
    let windowIDs: [String]
    let isCombined: Bool
    let frame: CGRect
}

struct TaskbarLayoutResult: Equatable {
    let buttons: [TaskbarButtonLayout]
    let overflowGroups: [String]
    let overflowFrame: CGRect?
    let combinedGroups: Set<String>
}

enum TaskbarLayout {
    private struct Candidate {
        let id: String
        let groupID: String
        let windowIDs: [String]
        let combined: Bool
        let desiredWidth: CGFloat
    }

    static func resolve(groups input: [TaskbarLayoutGroup], width: CGFloat) -> TaskbarLayoutResult {
        let groups = input.filter { !$0.windows.isEmpty }
        let available = width.isFinite ? max(0, width - TaskbarMetrics.leadingInset - TaskbarMetrics.trailingInset) : 0
        var combined = Set<String>()
        let priorities = groups.filter { $0.windows.count > 1 }
        var candidates = candidates(for: groups, combined: combined)
        for candidate in priorities where minimumWidth(candidates) > available {
            combined.insert(candidate.id)
            candidates = self.candidates(for: groups, combined: combined)
        }
        for group in priorities where combined.contains(group.id) {
            let expanded = combined.subtracting([group.id])
            let proposal = self.candidates(for: groups, combined: expanded)
            if minimumWidth(proposal) <= available {
                combined = expanded
                candidates = proposal
            }
        }

        var overflow: [String] = []
        var contentWidth = available
        if minimumWidth(candidates) > available {
            contentWidth = max(0, available - TaskbarMetrics.overflowWidth - TaskbarMetrics.buttonSpacing)
            while minimumWidth(candidates) > contentWidth, let last = candidates.last {
                overflow.insert(last.groupID, at: 0)
                candidates.removeAll { $0.groupID == last.groupID }
            }
        }

        let widths = fittedWidths(candidates.map(\.desiredWidth), available: contentWidth)
        var x = TaskbarMetrics.leadingInset
        let buttons = zip(candidates, widths).map { candidate, buttonWidth in
            defer { x += buttonWidth + TaskbarMetrics.buttonSpacing }
            return TaskbarButtonLayout(
                id: candidate.id,
                groupID: candidate.groupID,
                windowIDs: candidate.windowIDs,
                isCombined: candidate.combined,
                frame: CGRect(x: x, y: TaskbarMetrics.buttonTop, width: buttonWidth, height: TaskbarMetrics.buttonHeight)
            )
        }
        let overflowFrame = overflow.isEmpty ? nil : CGRect(
            x: min(x, max(TaskbarMetrics.leadingInset, width - TaskbarMetrics.trailingInset - TaskbarMetrics.overflowWidth)),
            y: TaskbarMetrics.buttonTop,
            width: min(TaskbarMetrics.overflowWidth, available),
            height: TaskbarMetrics.buttonHeight
        )
        return TaskbarLayoutResult(buttons: buttons, overflowGroups: overflow,
                                   overflowFrame: overflowFrame, combinedGroups: combined)
    }

    private static func candidates(for groups: [TaskbarLayoutGroup], combined: Set<String>) -> [Candidate] {
        groups.flatMap { group in
            if combined.contains(group.id) {
                return [Candidate(id: "group:" + group.id, groupID: group.id,
                                  windowIDs: group.windows.map(\.id), combined: true,
                                  desiredWidth: bounded(group.desiredWidth))]
            }
            return group.windows.map {
                Candidate(id: "window:" + $0.id, groupID: group.id, windowIDs: [$0.id],
                          combined: false, desiredWidth: bounded($0.desiredWidth))
            }
        }
    }

    private static func bounded(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return TaskbarMetrics.minimumCompressedButtonWidth }
        return min(TaskbarMetrics.maximumButtonWidth, max(TaskbarMetrics.labelInset + TaskbarMetrics.labelTrailingInset, width))
    }

    private static func minimumWidth(_ candidates: [Candidate]) -> CGFloat {
        candidates.reduce(0) { $0 + min($1.desiredWidth, TaskbarMetrics.minimumCompressedButtonWidth) }
            + CGFloat(max(0, candidates.count - 1)) * TaskbarMetrics.buttonSpacing
    }

    private static func fittedWidths(_ desired: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !desired.isEmpty else { return [] }
        let budget = max(0, available - CGFloat(desired.count - 1) * TaskbarMetrics.buttonSpacing)
        if desired.reduce(0, +) <= budget { return desired }
        var low: CGFloat = TaskbarMetrics.minimumCompressedButtonWidth
        var high: CGFloat = TaskbarMetrics.maximumButtonWidth
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if desired.reduce(0, { $0 + min($1, middle) }) > budget { high = middle }
            else { low = middle }
        }
        var exactEdge: CGFloat = 0
        var roundedEdge: CGFloat = 0
        return desired.map {
            exactEdge += min($0, low)
            let nextEdge = floor(exactEdge + 0.000001)
            defer { roundedEdge = nextEdge }
            return nextEdge - roundedEdge
        }
    }
}

enum TaskbarGroupOrdering {
    static func contiguous(_ order: [String], appKeys: [String: String]) -> [String] {
        var groups: [String] = []
        var members: [String: [String]] = [:]
        var seen = Set<String>()
        for id in order where seen.insert(id).inserted {
            let key = appKeys[id] ?? id
            if members[key] == nil { groups.append(key) }
            members[key, default: []].append(id)
        }
        return groups.flatMap { members[$0] ?? [] }
    }

    static func moving(_ app: String, relativeTo target: String, after: Bool,
                       order: [String], appKeys: [String: String]) -> [String] {
        let normalized = contiguous(order, appKeys: appKeys)
        guard app != target else { return normalized }
        let moved = normalized.filter { (appKeys[$0] ?? $0) == app }
        let others = normalized.filter { (appKeys[$0] ?? $0) != app }
        guard !moved.isEmpty,
              let first = others.firstIndex(where: { (appKeys[$0] ?? $0) == target }),
              let last = others.lastIndex(where: { (appKeys[$0] ?? $0) == target }) else { return normalized }
        var result = others
        result.insert(contentsOf: moved, at: after ? last + 1 : first)
        return result
    }
}

enum TaskbarPopupGeometry {
    static func frame(anchor: CGRect, contentSize: CGSize, screen: CGRect) -> CGRect {
        let width = min(max(0, contentSize.width), max(0, screen.width - 16))
        let height = min(max(0, contentSize.height), max(0, screen.height - TaskbarMetrics.height - TaskbarMetrics.popupGap - 8))
        let x = min(max(screen.minX + 8, anchor.midX - width / 2), screen.maxX - 8 - width)
        return CGRect(x: x, y: screen.minY + TaskbarMetrics.height + TaskbarMetrics.popupGap,
                      width: width, height: height)
    }

}
