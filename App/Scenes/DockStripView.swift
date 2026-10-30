import AppKit
import OSLog
import SwiftUI

struct DockStripView: View {
    @Environment(\.isPanelHeightResizing) var isPanelHeightResizing
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var stripOrderStore: StripOrderStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    @EnvironmentObject var displayTopologyStore: DisplayTopologyStore
    @EnvironmentObject var dragController: DragController
    @Environment(\.colorScheme) private var colorScheme

    let usesLiquidGlass: Bool
    let stripSurfaceID: String
    let displayUUID: String?

    var onWindowTitleTooltipEvent: (WindowTitleTooltipEvent) -> Void = { _ in }
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    var onInteractiveResize: (StripResizeGripEvent) -> Void = { _ in }
    var resizeGripController: StripResizeGripController?
    var onLabelWidthChange: ([String: CGFloat]) -> Void = { _ in }
    var onLabelBoxWidthTick: (String, CGFloat) -> Void = { _, _ in }

    @State var frames = StripFrameBox()
    @State var hoveredEntryID: String?
    @State var hoveredAnchor: CGRect?
    @State var pointerBox = PointerBox()
    @State private var renderedLabelTitles: [String: String] = [:]
    @State private var bubbleOwnerID: String?

    var ownsActiveDrag: Bool {
        dragController.activeStripSurfaceID.map { $0 == stripSurfaceID } ?? true
    }

    private var metrics: PanelLayoutMetrics { settingsStore.dockPanelHeight.metrics }
    var dockScale: CGFloat { settingsStore.dockPanelHeight.scale }
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    private var taskbarCornerRadius: CGFloat { Style.cornerRadius * dockScale }
    var chipFrames: [String: CGRect] { frames.chipFrames }
    var stripHoverFrames: [String: CGRect] { frames.stripHoverFrames }
    var stripRootScreenRect: CGRect { frames.stripRootScreenRect }

    var body: some View {
        let projectionStart = HoverTrace.now()
        let projection = makeProjection()
        let _ = StripProjectionRegistry.shared.store(projection, surface: stripSurfaceID, displayUUID: displayUUID)
        let _ = HoverTrace.span("makeProjection", since: projectionStart)
        let _ = HoverTrace.stripBody(items: projection.entries.count, surface: stripSurfaceID)
        return ZStack {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: taskbarCornerRadius,
                              usesLiquidGlass: usesLiquidGlass,
                              matchesDockRefraction: true)

            if theme.drawsEffectiveThickness && !usesLiquidGlass {
                theme.panelThicknessLayer(cornerRadius: taskbarCornerRadius)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: Style.chipSpacing * dockScale) {
                    ForEach(projection.entries) { entry in
                        chipWithReorder(entry, projection: projection)
                            .transition(Self.entryTransition)
                    }
                }
                .padding(.horizontal, Style.chipContentInset * dockScale)
                .frame(height: metrics.panelHeight)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: projection.layoutKeys)
                .onChange(of: projection.labelTitleByChipID) { newTitles in
                    HoverTrace.action("labelChange", phase: "swiftui")
                    let titled = Set(projection.layoutKeys.filter { $0.form == .multi }.map(\.id))
                    var starting: [String: CGFloat] = [:]
                    for id in titled {
                        guard let new = newTitles[id], let old = renderedLabelTitles[id], new != old else { continue }
                        let from = ChipPillMetrics.labelWidth(title: old, scale: dockScale)
                        if from != ChipPillMetrics.labelWidth(title: new, scale: dockScale) { starting[id] = from }
                    }
                    renderedLabelTitles = newTitles
                    if !starting.isEmpty { onLabelWidthChange(starting) }
                }
                .onAppear { renderedLabelTitles = projection.labelTitleByChipID }
                .environment(\.labelBoxWidthTick, onLabelBoxWidthTick)
                .environment(\.chipPillUsesGlass, usesLiquidGlass)
            }
            .clipShape(RoundedRectangle(cornerRadius: taskbarCornerRadius, style: .continuous))
            .defaultScrollAnchor(.leading)
            .mask(alignment: .center) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth * dockScale)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth * dockScale)
                }
            }
            .overlay(alignment: .topLeading) {
                WheelScrollInterceptorRepresentable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(StripResizeGripHost(
                shouldClaim: { resizeGripZoneClaims(atScreen: $0) },
                onEvent: onInteractiveResize,
                controller: resizeGripController
            ))
            .overlay(NativeMenuHost(
                popUpHandler: onRequestTaskbarMenu,
                shouldClaim: { taskbarMenuZoneClaims(atScreen: $0) }
            ))
        }
        .dockPanelRim(
            cornerRadius: taskbarCornerRadius,
            style: theme.panelRimStyle(highlighted: false),
            lineWidth: theme.panelRimLineWidth(highlighted: false),
            usesLiquidGlass: usesLiquidGlass
        )
        .coordinateSpace(name: "strip")
        .background(ScreenRectReader { rect in
            HoverTrace.stripInput("stripRect", surface: stripSurfaceID, changed: rect != frames.stripRootScreenRect)
            guard rect != frames.stripRootScreenRect else { return }
            frames.stripRootScreenRect = rect
            refreshHoveredEntry(frames: stripHoverFrames, origin: rect)
            updateLandingAnchor()
        })
        .background(StripPointerTracker { pointer in
            let enteredBar = pointerBox.value == nil && pointer != nil
            pointerBox.value = pointer
            if enteredBar {
                onInteractiveResize(.pointerEnteredBar(hitTest: { currentPointer in
                    (isInContent: stripRootScreenRect != .zero && stripRootScreenRect.contains(currentPointer),
                     isInGrip: resizeGripZoneClaims(atScreen: currentPointer))
                }))
            }
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
            onInteractiveResize(.hover(pointer.flatMap { resizeGripHoverClaims(atScreen: $0) ? $0 : nil }))
            HoverTrace.pointer(x: pointer?.x ?? -1, chip: hoveredEntryID)
        })
        .dockShadow(theme.stripShadow,
                    visible: DockLiquidGlassConfiguration.stripShadowVisible(
                        usesLiquidGlass: usesLiquidGlass,
                        usesSystemVariant: DockGlassPresentation.usesSystemVariant))
        .padding(PanelCoordinator.shadowPadding)
        .onReceive(dragController.pointerMoves) { _ in
            guard ownsActiveDrag else { return }
            updateLiveReorder(projection: projection)
            updateLandingAnchor()
        }
        .onReceive(dragController.carrierClicks) { payload in
            guard ownsActiveDrag else { return }
            performCarrierClick(payload, projection: freshProjection())
        }

        .onChange(of: dragController.hoverGate) { _ in
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
        }
        .onChange(of: isPanelHeightResizing) { _ in
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
        }
        .onChange(of: bubbleRequest(projection: projection)) { request in
            if let request {
                onWindowTitleTooltipEvent(.update(request))
            } else if let previous = bubbleOwnerID {
                onWindowTitleTooltipEvent(.exit(chipID: previous))
            }
            bubbleOwnerID = request?.chipID
        }
        .onDisappear {
            StripProjectionRegistry.shared.remove(surface: stripSurfaceID)
            if let previous = bubbleOwnerID { onWindowTitleTooltipEvent(.exit(chipID: previous)) }
            bubbleOwnerID = nil
        }
        .onChange(of: projection.liveOrderIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onAppear { reconcileLiveOrder(projection) }
        .onPreferenceChange(ChipFramePreferenceKey.self) { frames in
            HoverTrace.stripInput("chipFrames", surface: stripSurfaceID, changed: frames != self.frames.chipFrames)
            self.frames.chipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(StripHoverFramePreferenceKey.self) { frames in
            HoverTrace.stripInput("hoverFrames", surface: stripSurfaceID, changed: frames != self.frames.stripHoverFrames)
            self.frames.stripHoverFrames = frames
            refreshHoveredEntry(frames: frames, origin: stripRootScreenRect)
        }

    }

    func reconcileLiveOrder(_ projection: StripProjection) {
        let current = projection.liveOrderIDs
        stripOrderStore.sync(current: current, appKeyOf: projection.appKeyByChipID)
        if let payload = dragController.draggingPayload, !current.contains(payload.id) {
            dragController.cancelDrag()
        }
    }

    private func reorderTarget(at point: CGPoint, dragging id: String, current: [String]) {
        guard let hit = chipFrames.first(where: { kv in
            kv.key != id && kv.value.contains(point)
        }) else { return }
        stripOrderStore.reorder(draggedID: id, relativeTo: hit.key,
                                after: point.x > hit.value.midX, current: current)
    }

    private func updateLiveReorder(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .strip,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        reorderTarget(at: pt, dragging: p.id, current: projection.liveOrderIDs)
    }

    private func performCarrierClick(_ payload: DragPayload, projection: StripProjection) {
        guard let item = projection.item(forID: payload.id) else { return }
        runtime.toggle(windowID: item.actionWindowID)
    }

    func carriedStripEntryID(for payload: DragPayload) -> String? {
        payload.id
    }

    private func updateLandingAnchor() {
        guard ownsActiveDrag else { return }
        let anchor = dragController.carriedPayload.flatMap { chipFrames[$0.id] }.map(stripFrameToScreen)
        dragController.setLandingAnchor(anchor, owner: .strip)
    }

    private func carrierSnapshot(for entry: StripEntry, projection: StripProjection) -> CarrierSnapshot? {
        ChipSnapshotter.snapshot(
            of: stripEntryContent(entry, projection: projection, hovered: false, entrance: false)
                .environmentObject(runtime),
            screenPoint: CGPoint(x: stripRootScreenRect.midX, y: stripRootScreenRect.midY)
        )
    }

    private func pickUpPose(for entry: StripEntry, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        DragCarrierGeometry.pickUpPose(
            chipHeight: slot?.height ?? ChipPillMetrics.chipHeight * dockScale,
            pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
            hoverScale: nil
        )
    }

    private func prepareDragCandidate(_ entry: StripEntry, id: String, slot: CGRect?,
                                      projection: StripProjection) {
        guard let slot, stripRootScreenRect != .zero else { return }
        dragController.prepareCandidate(payloadID: id,
                                        sourceScreenRect: stripFrameToScreen(slot),
                                        snapshot: carrierSnapshot(for: entry, projection: projection))
    }

    func stripPoint(from global: CGPoint) -> CGPoint? {
        guard stripRootScreenRect != .zero else { return nil }
        return CGPoint(x: global.x - stripRootScreenRect.minX,
                       y: stripRootScreenRect.maxY - global.y)
    }

    func stripFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: stripRootScreenRect.minX + frame.minX,
               y: stripRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    @ViewBuilder
    private func chipWithReorder(_ entry: StripEntry, projection: StripProjection) -> some View {
        switch entry {
        case let .window(item):
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == item.id ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [item.id: geo.frame(in: .named("strip"))])
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: item.id, slot: chipFrames[item.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: item.id) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[item.id]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: item.id,
                                                          bundleID: item.bundleIdentifier ?? "",
                                                          item: item, visualKind: .stripChip)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        }
    }

    @ViewBuilder
    private func stripEntryView(_ entry: StripEntry, projection: StripProjection) -> some View {
        stripEntryContent(entry, projection: projection,
                          hovered: hoveredEntryID == entry.id, entrance: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: StripHoverFramePreferenceKey.self,
                                           value: [entry.id: geo.frame(in: .named("strip"))])
                }
            )
    }

    @ViewBuilder
    private func stripEntryContent(
        _ entry: StripEntry,
        projection: StripProjection,
        hovered: Bool,
        entrance: Bool
    ) -> some View {
        switch entry {
        case let .window(item):
            ChipView(
                item: item,
                labelTitle: projection.labelTitleByChipID[item.id] ?? item.title,
                scale: dockScale,
                isHovered: hovered,
                slotHidden: projection.draggingID == item.id
            )
        }
    }

    static var entryTransition: AnyTransition {
        .scale(scale: 0.88).combined(with: .opacity)
    }

}

private enum Style {
    static let cornerRadius: CGFloat = DockShape.panelCornerRadius
    static let chipContentInset: CGFloat = DebugSwitch.stripBalancedInsets.isEnabled()
        ? (ChipPillMetrics.chipHeight - ChipPillMetrics.cardWidth) / 2
        : 20
    static let edgeFadeWidth: CGFloat = min(16, chipContentInset)
    static let chipSpacing: CGFloat = ChipPillMetrics.chipSpacing
}
