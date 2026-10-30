import CoreGraphics

struct DockPanelHeight: Equatable {
    static let minimum: CGFloat = 32
    static let maximum: CGFloat = 120

    static let native = DockPanelHeight(validated: 54)
    static let `default` = native

    let points: CGFloat

    init(clamping raw: CGFloat) {
        guard raw.isFinite else {
            self = .default
            return
        }
        self.init(validated: min(max(raw.rounded(), Self.minimum), Self.maximum))
    }

    private init(validated points: CGFloat) {
        self.points = points
    }

    var scale: CGFloat { points / Self.native.points }

    static func migratingLegacyTier(rawValue: String) -> DockPanelHeight? {
        switch rawValue {
        case "small": return DockPanelHeight(clamping: 46)
        case "medium": return DockPanelHeight(clamping: 54)
        case "large": return DockPanelHeight(clamping: 62)
        case "extraLarge": return DockPanelHeight(clamping: 70)
        default: return nil
        }
    }

    var metrics: PanelLayoutMetrics {
        PanelLayoutMetrics(
            panelHeight: points,
            shadowPadding: PanelLayoutMetrics.shadowPadding,
            windowHeight: points + 2 * PanelLayoutMetrics.shadowPadding,
            bottomGap: 8,
            outerMargin: 12,
            minimumDockWidth: 120 * scale
        )
    }
}

struct PanelLayoutMetrics: Equatable {
    var panelHeight: CGFloat
    var shadowPadding: CGFloat
    var windowHeight: CGFloat
    var bottomGap: CGFloat
    var outerMargin: CGFloat
    var minimumDockWidth: CGFloat

    static let shadowPadding: CGFloat = 20

    static let tungstenEdge = DockPanelHeight.native.metrics
}

struct PanelScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat

    var topUsableY: CGFloat {
        min(visibleFrame.maxY, frame.maxY - safeAreaTop)
    }
}

enum PanelGeometry {
    static let windowTitleTooltipScreenMargin: CGFloat = 8
    static let windowTitleTooltipShadowPadding: CGFloat = 8

    static func dockTargetFrame(
        contentWidth: CGFloat,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let maxWidth = screen.frame.width - 2 * metrics.outerMargin
        let panelWidth = max(min(contentWidth, maxWidth), metrics.minimumDockWidth)
        let x = screen.frame.minX + (screen.frame.width - panelWidth) / 2
        return CGRect(
            x: x - metrics.shadowPadding,
            y: screen.frame.minY + metrics.bottomGap - metrics.shadowPadding,
            width: panelWidth + metrics.shadowPadding * 2,
            height: metrics.windowHeight
        )
    }

    static func windowTitleTooltipTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        tipGap: CGFloat,
        on screen: PanelScreenGeometry
    ) -> CGRect {
        let inset = windowTitleTooltipShadowPadding
        let visibleWidth = max(0, size.width - 2 * inset)
        let visibleHeight = max(0, size.height - 2 * inset)
        let minVisibleX = screen.frame.minX + windowTitleTooltipScreenMargin
        let maxVisibleX = screen.frame.maxX - windowTitleTooltipScreenMargin - visibleWidth
        let desiredVisibleX = anchorVisibleRect.midX - visibleWidth / 2
        let visibleX = min(max(desiredVisibleX, minVisibleX), maxVisibleX)
        let desiredVisibleY = anchorVisibleRect.maxY + tipGap
        let maxVisibleY = screen.topUsableY - visibleHeight
        let visibleY = min(desiredVisibleY, maxVisibleY)

        return CGRect(
            x: visibleX - inset,
            y: visibleY - inset,
            width: size.width,
            height: size.height
        )
    }

}
