import AppKit
import os
import SwiftUI

enum WindowTitleTextMetrics {
    static let maximumWidth: CGFloat = 140

    static func maximumWidth(for scale: CGFloat) -> CGFloat { maximumWidth * scale }

    static func font(scale: CGFloat) -> NSFont {
        let size = max(10, 12 * scale)
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return rounded
    }

    static func intrinsicWidth(of title: String, scale: CGFloat) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font(scale: scale)]).width
    }

}

enum LabelWidthAnimation {
    struct Curve: Equatable {
        let duration: TimeInterval
        let c1x: Double, c1y: Double, c2x: Double, c2y: Double
    }

    static let defaultCurve = Curve(duration: 0.60, c1x: 0.5, c1y: 0, c2x: 0.15, c2y: 1)   // owner 2026-09-13：起点缓、整体长
    static let curve: Curve = parse(DebugSwitch.labelAnim.value()) ?? defaultCurve

    static var swiftUI: Animation {
        .timingCurve(curve.c1x, curve.c1y, curve.c2x, curve.c2y, duration: curve.duration)
    }

    static func parse(_ raw: String?) -> Curve? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 5, let ms = parts[0], let c1x = parts[1], let c1y = parts[2],
              let c2x = parts[3], let c2y = parts[4], ms > 0,
              (0...1).contains(c1x), (0...1).contains(c2x) else { return nil }
        return Curve(duration: ms / 1000, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y)
    }
}

enum ChipPillMetrics {
    static let chipHeight: CGFloat = 54
    static let boxHeight: CGFloat = 34
    static let horizontalPadding: CGFloat = 10
    static let titledCardInset: CGFloat = 4
    static let iconSlot: CGFloat = 22
    static let iconSpacing: CGFloat = 6

    static let bareIconSlot: CGFloat = 40
    static let bareIconVisibleSlot: CGFloat = 32.5

    static let runningDotSize: CGFloat = 4
    static let runningDotBottomPadding: CGFloat = 4

    static var visibleIconBottomFraction: CGFloat {
        let slotBottom = (chipHeight + bareIconSlot) / 2
        let artworkMargin = (bareIconSlot - bareIconVisibleSlot) / 2
        return (slotBottom - artworkMargin) / chipHeight
    }

    static let cardWidth: CGFloat = 40

    static let chipSpacing: CGFloat = 2

    static let iconPitch: CGFloat = cardWidth + chipSpacing

    static let badgeFontSize: CGFloat = 10
    static let badgeMinimumSize: CGFloat = 16
    static let badgeHorizontalPadding: CGFloat = 5
    static let badgeTopOffset: CGFloat = 5
    static let titledCardBadgeScale: CGFloat = 0.8

    static let boxTopInset: CGFloat = (chipHeight - boxHeight) / 2

    static func height(scale: CGFloat) -> CGFloat { boxHeight * scale }

    static func labelWidth(title: String, scale: CGFloat) -> CGFloat {
        ceil(min(
            WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale),
            WindowTitleTextMetrics.maximumWidth(for: scale)
        ))
    }

    static func labelTruncates(title: String, scale: CGFloat) -> Bool {
        WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale)
            > WindowTitleTextMetrics.maximumWidth(for: scale)
    }

    static func width(title: String, scale: CGFloat) -> CGFloat {
        (2 * horizontalPadding + iconSlot + iconSpacing) * scale + labelWidth(title: title, scale: scale)
    }

    static func pillRect(
        inCard card: CGRect,
        title: String,
        scale: CGFloat
    ) -> CGRect {
        let pillHeight = height(scale: scale)
        let topY = card.maxY - boxTopInset * scale
        let pillWidth = width(title: title, scale: scale)
        return CGRect(
            x: card.midX - pillWidth / 2,
            y: topY - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
    }
}

struct ChipHoverVisual: Equatable {
    let progress: CGFloat
    let bareIconSize: CGFloat
    let pillHeight: CGFloat
    let pillIconSize: CGFloat
    let emphasisProgress: Double

    static func resolve(progress rawProgress: CGFloat, scale: CGFloat) -> ChipHoverVisual {
        let progress = min(max(rawProgress, 0), 1)
        return ChipHoverVisual(
            progress: progress,
            bareIconSize: ChipPillMetrics.bareIconSlot * scale,
            pillHeight: ChipPillMetrics.boxHeight * scale,
            pillIconSize: ChipPillMetrics.iconSlot * scale,
            emphasisProgress: Double(progress)
        )
    }
}

struct ChipHoverProgress<Content: View>: View, Animatable {
    var progress: CGFloat
    let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    init(progress: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.progress = progress
        self.content = content
    }

    var body: some View {
        content(min(max(progress, 0), 1))
    }
}

enum ChipAnimationTrace {
    private static let enabled = DebugSwitch.chipAnimTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let runtime = Runtime()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.sashokey.properwm",
        category: "ChipAnimation"
    )

    static func record(
        chipID: String,
        kind: String,
        visual: ChipHoverVisual,
        isTapPressed: Bool,
        showsHover: Bool
    ) {
        guard enabled else { return }
        runtime.record(
            chipID: chipID,
            kind: kind,
            uptime: ProcessInfo.processInfo.systemUptime,
            visual: visual,
            state: ChipAnimationTraceState(isTapPressed: isTapPressed, showsHover: showsHover)
        )
    }

    static func event(
        chipID: String,
        kind: String,
        event: String,
        isTapPressed: Bool,
        showsHover: Bool
    ) {
        guard enabled else { return }
        runtime.event(
            chipID: chipID,
            kind: kind,
            uptime: ProcessInfo.processInfo.systemUptime,
            event: event,
            state: ChipAnimationTraceState(isTapPressed: isTapPressed, showsHover: showsHover)
        )
    }

    private final class Runtime: @unchecked Sendable {
        private let queue = DispatchQueue(label: "io.github.sashokey.properwm.chip-animation-trace")
        private let fileManager = FileManager.default
        private var buffer = ChipAnimationTraceBuffer(capacity: 4_096)
        private var sessionByChip: [String: UUID] = [:]
        private var lastVisualByChip: [String: ChipHoverVisual] = [:]
        private var quiescenceGeneration: UInt64 = 0

        func record(
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            visual: ChipHoverVisual,
            state: ChipAnimationTraceState
        ) {
            queue.async { [self] in
                let key = "\(kind)\u{0}\(chipID)"
                let isNewSession = sessionByChip[key] == nil
                let sessionID = sessionByChip[key] ?? UUID()
                sessionByChip[key] = sessionID
                lastVisualByChip[key] = visual
                appendSample(
                    sessionID: sessionID,
                    chipID: chipID,
                    kind: kind,
                    uptime: uptime,
                    visual: visual,
                    state: state,
                    event: isNewSession ? "sessionStart" : nil
                )
                scheduleExportAfterQuiescence()
            }
        }

        func event(
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            event: String,
            state: ChipAnimationTraceState
        ) {
            queue.async { [self] in
                let key = "\(kind)\u{0}\(chipID)"
                let sessionID = sessionByChip[key] ?? UUID()
                sessionByChip[key] = sessionID
                appendSample(
                    sessionID: sessionID,
                    chipID: chipID,
                    kind: kind,
                    uptime: uptime,
                    visual: lastVisualByChip[key],
                    state: state,
                    event: event
                )
                scheduleExportAfterQuiescence()
            }
        }

        private func appendSample(
            sessionID: UUID,
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            visual: ChipHoverVisual?,
            state: ChipAnimationTraceState,
            event: String?
        ) {
            buffer.append(ChipAnimationTraceSample(
                sessionID: sessionID,
                chipID: chipID,
                kind: kind,
                uptime: uptime,
                hoverProgress: visual.map { Double($0.progress) },
                bareIconSize: visual.map { Double($0.bareIconSize) },
                pillHeight: visual.map { Double($0.pillHeight) },
                pillIconSize: visual.map { Double($0.pillIconSize) },
                emphasisProgress: visual?.emphasisProgress,
                isTapPressed: state.isTapPressed,
                showsHover: state.showsHover,
                event: event
            ))
        }

        private func scheduleExportAfterQuiescence() {
            quiescenceGeneration &+= 1
            let generation = quiescenceGeneration
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.quiescenceGeneration == generation else { return }
                self.exportBufferedSamples()
            }
        }

        private func exportBufferedSamples() {
            let samples = buffer.drain()
            guard !samples.isEmpty else { return }
            sessionByChip.removeAll(keepingCapacity: true)
            lastVisualByChip.removeAll(keepingCapacity: true)

            do {
                let url = try traceFileURL()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var payload = Data()
                for sample in samples {
                    payload.append(try encoder.encode(sample))
                    payload.append(0x0A)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                let sessionCount = Set(samples.map(\.sessionID)).count
                ChipAnimationTrace.logger.info(
                    "exported samples=\(samples.count) sessions=\(sessionCount) path=\(url.path, privacy: .public)"
                )
            } catch {
                ChipAnimationTrace.logger.error("trace export failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func traceFileURL() throws -> URL {
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            let directory = library
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("io.github.sashokey.properwm", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent("chip-animation-trace.jsonl")
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return url
        }
    }
}

struct ChipAnimationTraceState: Equatable {
    let isTapPressed: Bool
    let showsHover: Bool
}

enum ChipAnimationTraceEvent {
    static func hover(_ hovering: Bool) -> String { hovering ? "hoverEntered" : "hoverExited" }
    static func tap(_ pressed: Bool) -> String { pressed ? "tapPressed" : "tapReleased" }
}

struct ChipAnimationTraceSample: Codable, Equatable {
    let sessionID: UUID
    let chipID: String
    let kind: String
    let uptime: TimeInterval
    let hoverProgress: Double?
    let bareIconSize: Double?
    let pillHeight: Double?
    let pillIconSize: Double?
    let emphasisProgress: Double?
    let isTapPressed: Bool
    let showsHover: Bool
    let event: String?
}

struct ChipAnimationTraceBuffer {
    let capacity: Int
    private(set) var samples: [ChipAnimationTraceSample] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: ChipAnimationTraceSample) {
        if samples.count == capacity {
            samples.removeFirst()
        }
        samples.append(sample)
    }

    mutating func drain() -> [ChipAnimationTraceSample] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }
}

struct WindowTitleTooltipRequest: Equatable {
    let chipID: String
    let title: String
    let anchorVisibleRect: CGRect
}

enum WindowTitleTooltipEvent: Equatable {
    case update(WindowTitleTooltipRequest)
    case exit(chipID: String)
}

struct WindowTitleTooltipStyle: Equatable {
    let height: CGFloat
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let fontSize: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    let tailShoulderDepth: CGFloat
    let tailShoulderHalfWidth: CGFloat
    let tailTipDepth: CGFloat
    let tailTipHalfWidth: CGFloat
    let tipGap: CGFloat
    let maximumWidth: CGFloat

    private init() {
        height = 26
        cornerRadius = height / 2
        horizontalPadding = 13
        fontSize = 14
        tailWidth = 23
        tailHeight = 6.5
        tailShoulderDepth = 1.6
        tailShoulderHalfWidth = 6.6
        tailTipDepth = 5.6
        tailTipHalfWidth = 1.9
        tipGap = 6.5
        maximumWidth = 360
    }

    static let native = WindowTitleTooltipStyle()
}

struct WindowTitleTooltipShape: InsettableShape {
    let style: WindowTitleTooltipStyle
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in outerRect: CGRect) -> Path {
        let rect = outerRect.insetBy(dx: insetAmount, dy: insetAmount)
        let tail = style.tailHeight
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: max(0, rect.height - tail))
        let radius = min(style.cornerRadius, body.height / 2)
        let halfTail = min(style.tailWidth, body.width) / 2
        let centerX = body.midX

        var path = Path()
        path.move(to: CGPoint(x: body.maxX - radius, y: body.maxY))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.midY),
                    radius: radius, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.midY),
                    radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        let base = body.maxY
        let shoulderY = base + style.tailShoulderDepth
        let shoulderX = style.tailShoulderHalfWidth
        let tipY = base + style.tailTipDepth
        let tipX = style.tailTipHalfWidth
        let capControlY = 2 * (base + tail) - tipY

        path.addLine(to: CGPoint(x: centerX - halfTail, y: base))
        path.addQuadCurve(to: CGPoint(x: centerX - shoulderX, y: shoulderY),
                          control: CGPoint(x: centerX - halfTail * 0.83, y: base + tail * 0.05))
        path.addLine(to: CGPoint(x: centerX - tipX, y: tipY))
        path.addQuadCurve(to: CGPoint(x: centerX + tipX, y: tipY),
                          control: CGPoint(x: centerX, y: capControlY))
        path.addLine(to: CGPoint(x: centerX + shoulderX, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: centerX + halfTail, y: base),
                          control: CGPoint(x: centerX + halfTail * 0.83, y: base + tail * 0.05))
        path.closeSubpath()
        return path
    }
}

struct WindowTitleTooltipView: View {
    let title: String
    let style: WindowTitleTooltipStyle
    let usesLiquidGlass: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }

    var body: some View {
        let shape = WindowTitleTooltipShape(style: style)
        return label
            .frame(maxWidth: style.maximumWidth)
            .padding(.horizontal, style.horizontalPadding)
            .frame(height: style.height)
            .padding(.bottom, style.tailHeight)
            .background(plate(shape: shape))
            .overlay {
                if drawsOwnChrome { shape.strokeBorder(theme.tooltipRim.color, lineWidth: 0.5) }
            }
            .dockShadow(theme.tooltipShadow, visible: drawsOwnChrome)
            .padding(PanelGeometry.windowTitleTooltipShadowPadding)
    }

    @ViewBuilder
    private var label: some View {
        if theme.tooltipTextSmoothing {
            Text(title)
                .font(.system(size: style.fontSize, weight: .regular))
                .foregroundStyle(theme.tooltipText.color)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            let size = UnsmoothedLabel.size(of: title, fontSize: style.fontSize, maximumWidth: style.maximumWidth)
            UnsmoothedLabel(title: title, fontSize: style.fontSize, tint: theme.tooltipText)
                .frame(width: size.width, height: size.height)
        }
    }

    private var drawsOwnChrome: Bool {
        guard #available(macOS 26.0, *), usesLiquidGlass else { return true }
        return theme.tooltipGlassSurface == .plateOverClearGlass
    }

    @ViewBuilder
    private func plate(shape: WindowTitleTooltipShape) -> some View {
        let plate = shape.fill(theme.tooltipPlate.color.opacity(theme.tooltipPlateOpacity))
        if #available(macOS 26.0, *), usesLiquidGlass, theme.tooltipGlassSurface == .regularGlassAlone {
            shape
                .fill(Color.clear)
                .glassEffect(.regular.interactive(false), in: shape)
                .materialActiveAppearance(.active)
                .environment(\.appearsActive, true)
        } else if #available(macOS 26.0, *), usesLiquidGlass {
            plate.background {
                shape
                    .fill(Color.clear)
                    .glassEffect(.clear.interactive(false), in: shape)
                    .materialActiveAppearance(.active)
                    .environment(\.appearsActive, true)
            }
        } else {
            plate
        }
    }
}

private struct UnsmoothedLabel: NSViewRepresentable {
    let title: String
    let fontSize: CGFloat
    let tint: DockTint

    private static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .regular) }

    static func size(of title: String, fontSize: CGFloat, maximumWidth: CGFloat) -> CGSize {
        let size = (title as NSString).size(withAttributes: [.font: font(fontSize)])
        return CGSize(width: min(ceil(size.width), maximumWidth), height: ceil(size.height))
    }

    func makeNSView(context: Context) -> UnsmoothedLabelView {
        let view = UnsmoothedLabelView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: UnsmoothedLabelView, context: Context) { apply(to: view) }

    private func apply(to view: UnsmoothedLabelView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let colour = NSColor(white: tint.base == .white ? 1 : 0, alpha: tint.opacity)
        view.set(NSAttributedString(string: title, attributes: [
            .font: Self.font(fontSize),
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
        ]))
    }
}

final class UnsmoothedLabelView: NSView {
    private var text = NSAttributedString()

    override var isFlipped: Bool { true }

    func set(_ text: NSAttributedString) {
        guard text != self.text else { return }
        self.text = text
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldSmoothFonts(false)
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
