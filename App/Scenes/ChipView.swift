import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private struct LabelBoxWidthDriver<Content: View>: View, @MainActor Animatable {
    var width: CGFloat
    let chipID: String
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.labelBoxWidthTick) private var tick
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    var body: some View {
        let _ = tick(chipID, width)
        let _ = HoverTrace.width("boxA:" + String(chipID.suffix(4)), width)
        content(width)
    }
}

struct LabelBoxWidthTickKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String, CGFloat) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var labelBoxWidthTick: @MainActor @Sendable (String, CGFloat) -> Void {
        get { self[LabelBoxWidthTickKey.self] }
        set { self[LabelBoxWidthTickKey.self] = newValue }
    }
}

struct ChipView: View {
    @ObservedObject private var iconRevision = AppIconRevision.shared
    @EnvironmentObject var runtime: AppRuntime
    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    let item: StripItem
    let labelTitle: String
    let scale: CGFloat
    let isHovered: Bool
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot
    @Environment(\.chipPillUsesGlass) private var pillUsesGlass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing
    var slotHidden: Bool = false
    @State private var isTapPressed = false

    private var showsHover: Bool { isHovered }
    private var animationTraceKind: String {
        item.showsTitle ? "window" : "icon"
    }

    private func recordPressEvent(_ pressed: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.tap(pressed),
            isTapPressed: pressed,
            showsHover: showsHover
        )
    }

    private func recordHoverEvent(_ hovering: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.hover(hovering),
            isTapPressed: isTapPressed,
            showsHover: hovering
        )
    }

    private var effectiveStatus: String {
        runtime.optimisticStatesByWindowID[item.actionWindowID]?.status.rawValue ?? item.status
    }

    private var effectiveIsOnDesktop: Bool {
        guard let optimistic = runtime.optimisticStatesByWindowID[item.actionWindowID] else {
            return item.isOnDesktop
        }
        return optimistic.status == .active
    }

    var body: some View {
        Group {
            if item.showsTitle {
                multiWindowChip
            } else {
                bareIconChip
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.showsTitle)
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
    }

    private var bareIconChip: some View {
        let capturedFullTitle = fullTitle
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: item.id,
            kind: "icon",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            appIcon(size: hover.bareIconSize)
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.bareIconSlot * scale,
                   alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        .overlay(alignment: .bottom) {
            if !isDragCarrierSnapshot {
                Capsule()
                    .fill(theme.runningDot.color)
                    .frame(width: ChipPillMetrics.runningDotSize * scale,
                           height: ChipPillMetrics.runningDotSize * scale)
                    .padding(.bottom, ChipPillMetrics.runningDotBottomPadding * scale)
            }
        }
        .chipPressScale(isTapPressed)
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            runtime.toggle(windowID: item.actionWindowID)
        }
        .chipPressGesture(
            isPressed: $isTapPressed,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        .help(capturedFullTitle)
    }

    private var pillEmphasisBackground: some View {
        ChipHoverProgress(progress: showsHover ? 1 : 0) { progress in
            let shape = RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
            let _ = ChipAnimationTrace.record(
                chipID: item.id,
                kind: "window",
                visual: ChipHoverVisual.resolve(progress: progress, scale: scale),
                isTapPressed: isTapPressed,
                showsHover: showsHover
            )
            if pillUsesGlass, let glass = theme.chipPillGlass {
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(glass.tint.color).interactive(false), in: shape)
                    .overlay(shape.fill(DockTint(base: glass.hoverLift.base,
                                                 opacity: glass.hoverLift.opacity * Double(progress)).color))
            } else {
                shape
                    .fill(theme.effectiveChipPillFill.color(emphasisProgress: Double(progress)))
                    .overlay(
                        shape.strokeBorder(
                            theme.chipPillRimStyle(emphasisProgress: Double(progress)),
                            lineWidth: 0.5
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsHover)
    }

    private var multiWindowChip: some View {
        let titleColor: Color = effectiveIsOnDesktop ? theme.labelActive.color : theme.effectiveLabelInactive.color
        let capturedDisplayTitle = displayTitle
        let capturedFullTitle = fullTitle
        let metrics = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let pill = HStack(spacing: ChipPillMetrics.iconSpacing * scale) {
            appIcon(size: metrics.pillIconSize)
                .frame(width: ChipPillMetrics.iconSlot * scale, height: ChipPillMetrics.iconSlot * scale)
            titleLabel(capturedDisplayTitle, color: titleColor)
        }
        .padding(.horizontal, ChipPillMetrics.horizontalPadding * scale)
        .frame(height: metrics.pillHeight)
        .background(pillEmphasisBackground)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .frame(height: ChipPillMetrics.boxHeight * scale, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(height: ChipPillMetrics.chipHeight * scale)
        .padding(.horizontal, ChipPillMetrics.titledCardInset * scale)
        .chipPressScale(isTapPressed)
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            runtime.toggle(windowID: item.actionWindowID)
        }
        .chipPressGesture(
            isPressed: $isTapPressed,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        .help(capturedFullTitle)
    }

    private static let labelRemoval: Animation = .easeOut(duration: 0.16)
    private static let labelInsertion: Animation = .easeOut(duration: 0.34).delay(0.14)
    private static let labelInsertionOffset: CGFloat = 3

    private func titleLabel(_ title: String, color: Color) -> some View {
        let boxWidth = ChipPillMetrics.labelWidth(title: title, scale: scale)
        let truncates = ChipPillMetrics.labelTruncates(title: title, scale: scale)
        return LabelBoxWidthDriver(width: boxWidth, chipID: item.id) { liveWidth in ZStack(alignment: .leading) {
            Text(title)
                .font(.system(size: max(10, 12 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: truncates ? WindowTitleTextMetrics.maximumWidth(for: scale) : nil,
                       alignment: .leading)
                .fixedSize(horizontal: !truncates, vertical: false)
                .id(title)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(x: -Self.labelInsertionOffset * scale))
                        .animation(Self.labelInsertion),
                    removal: .opacity.animation(Self.labelRemoval)
                ))
        }
        .animation(Self.labelInsertion, value: title)
        .frame(width: liveWidth, alignment: .leading)
        .clipped()
        }
        .animation(LabelWidthAnimation.swiftUI, value: boxWidth)
    }

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID, points: size,
                                             displayScale: displayScale, colorScheme: colorScheme,
                                             allowsRendering: !isPanelHeightResizing))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }

    private func buildChipMenu() -> NSMenu {
        let menu = NSMenu()
        let restoreTitle = effectiveStatus == "minimized"
            ? String(localized: "Restore")
            : String(localized: "Show")
        menu.addItem(ClosureMenuItem(restoreTitle) {
            runtime.activate(windowID: item.actionWindowID)
        })
        if item.canMinimize, effectiveStatus != "minimized" {
            menu.addItem(ClosureMenuItem(String(localized: "Minimize")) {
                runtime.minimize(windowID: item.actionWindowID)
            })
        }
        if item.canClose {
            menu.addItem(ClosureMenuItem(String(localized: "Close Window")) {
                for windowID in item.memberWindowIDs {
                    runtime.close(windowID: windowID)
                }
            })
        }
        return menu
    }

    private var displayTitle: String { labelTitle }

    private var fullTitle: String {
        WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
    }

    private var appName: String {
        let name = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }
}
