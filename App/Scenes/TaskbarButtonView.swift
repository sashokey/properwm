import AppKit

@MainActor
final class TaskbarButtonView: NSView {
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var isActiveWindow = false { didSet { needsDisplay = true } }
    var isCombined = false { didSet { needsDisplay = true } }
    var isOverflow = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onBeginDrag: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    private var downPoint: CGPoint?
    private var beganDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        downPoint = convert(event.locationInWindow, from: nil)
        pressed = true
        beganDrag = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !beganDrag, let downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return }
        beganDrag = true
        pressed = false
        needsDisplay = true
        onBeginDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldClick = downPoint != nil && !beganDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        downPoint = nil
        pressed = false
        needsDisplay = true
        if shouldClick { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onClick?() }
        else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: TaskbarMetrics.buttonCornerRadius,
                                 yRadius: TaskbarMetrics.buttonCornerRadius)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isActiveWindow || hovered || pressed {
            let value: CGFloat = dark ? 1 : 0
            let alpha: CGFloat = pressed ? 0.11 : hovered ? 0.09 : 0.065
            NSColor(white: value, alpha: alpha).setFill()
            plate.fill()
            NSColor(white: value, alpha: dark ? 0.10 : 0.06).setStroke()
            plate.lineWidth = 1
            plate.stroke()
        }

        if isOverflow {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.labelColor
            ]
            let text = "···" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }

        image?.draw(in: CGRect(x: TaskbarMetrics.iconInset, y: 6, width: TaskbarMetrics.iconSize, height: TaskbarMetrics.iconSize),
                    from: .zero, operation: .sourceOver, fraction: pressed ? 0.8 : 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: TaskbarMetrics.fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(in: CGRect(x: TaskbarMetrics.labelInset,
                                            y: floor((bounds.height - size.height) / 2),
                                            width: max(0, bounds.width - TaskbarMetrics.labelInset - TaskbarMetrics.labelTrailingInset),
                                            height: ceil(size.height)), withAttributes: attributes)
        let indicatorWidth: CGFloat = isActiveWindow ? 16 : 4
        let indicator = NSBezierPath(roundedRect: CGRect(x: TaskbarMetrics.iconInset + (16 - indicatorWidth) / 2,
                                                         y: 24, width: indicatorWidth, height: 2),
                                     xRadius: 1, yRadius: 1)
        (isActiveWindow ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        indicator.fill()
        if isCombined {
            let line = NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 3, y: 3, width: 2, height: 22), xRadius: 1, yRadius: 1)
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            line.fill()
        }
    }
}
