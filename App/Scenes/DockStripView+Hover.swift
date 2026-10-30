import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

extension DockStripView {

    func refreshHoveredEntry(frames: [String: CGRect], origin: CGRect) {
        guard !dragController.hoverFrozen else { return }
        let resolved: String? = {
            guard !isPanelHeightResizing else { return nil }
            guard !dragController.hoverSuppressed else { return nil }
            guard let pointer = pointerBox.value, origin != .zero else { return nil }
            let point = CGPoint(x: pointer.x - origin.minX, y: origin.maxY - pointer.y)
            let hit = StripHoverResolution.chip(
                at: point,
                frames: frames,
                gapBridge: StripHoverResolution.defaultGapBridge * dockScale
            )
            if let exempt = dragController.hoverExemptPayload,
               carriedStripEntryID(for: exempt) == hit { return nil }
            return hit
        }()
        HoverTrace.stripInput("hoveredEntry", surface: stripSurfaceID, changed: resolved != hoveredEntryID)
        if resolved != hoveredEntryID { hoveredEntryID = resolved }
        let anchor: CGRect? = {
            guard let resolved, origin != .zero, let frame = frames[resolved] else { return nil }
            return CGRect(x: origin.minX + frame.minX, y: origin.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        }()
        if anchor != hoveredAnchor { hoveredAnchor = anchor }
    }

    private func bubbleTitle(for entry: StripEntry) -> String? {
        switch entry {
        case let .window(item):
            return appBubbleName(bundleID: item.bundleIdentifier, fallback: item.appID)
        }
    }

    private func appBubbleName(bundleID: String?, fallback: String) -> String {
        let name = bundleID.map(AppDisplayNameResolver.displayName(for:)) ?? fallback
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }

    func bubbleRequest(projection: StripProjection) -> WindowTitleTooltipRequest? {
        guard !isPanelHeightResizing,
              let id = hoveredEntryID,
              let anchor = hoveredAnchor,
              let entry = projection.entries.first(where: { $0.id == id }),
              let title = bubbleTitle(for: entry) else { return nil }
        return WindowTitleTooltipRequest(chipID: id, title: title, anchorVisibleRect: anchor)
    }

    func taskbarMenuZoneClaims(atScreen global: CGPoint) -> Bool {
        guard let point = stripPoint(from: global) else { return false }
        return StripContextMenuZone.claims(
            point: point,
            chipFrames: allStripChipFrames(),
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: StripContextMenuZone.defaultMinimumGapWidth * dockScale
        )
    }

    func resizeGripZoneClaims(atScreen global: CGPoint) -> Bool {
        guard let point = stripPoint(from: global) else { return false }
        return StripContextMenuZone.gripClaims(
            point: point,
            chipFrames: allStripChipFrames(),
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: StripContextMenuZone.defaultMinimumGapWidth * dockScale,
            chipClearance: StripContextMenuZone.defaultGripChipClearance * dockScale
        )
    }

    func resizeGripHoverClaims(atScreen global: CGPoint) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 == 0, dragController.draggingPayload == nil else { return false }
        return resizeGripZoneClaims(atScreen: global)
    }

    private func allStripChipFrames() -> [CGRect] {
        Array(chipFrames.values)
    }
}
