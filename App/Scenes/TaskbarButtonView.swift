import AppKit
import QuartzCore

@MainActor
private final class TaskbarButtonContentView: NSView {
    weak var button: TaskbarButtonView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { button?.drawContent() }
}

@MainActor
final class TaskbarButtonView: NSView {
    var title = "" { didSet { content.needsDisplay = true; setAccessibilityLabel(title) } }
    var image: NSImage? { didSet { content.needsDisplay = true } }
    var isActiveWindow = false { didSet { if oldValue != isActiveWindow { updateAppearance(animated: true) } } }
    var isCombined = false { didSet { content.needsDisplay = true } }
    var isOverflow = false { didSet { if oldValue != isOverflow { content.needsDisplay = true; updateAppearance(animated: false) } } }
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onBeginDrag: ((NSEvent, CGPoint) -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onEndDrag: ((NSEvent?, Bool) -> Void)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    let plateLayer = CAShapeLayer()
    let indicatorLayer = CALayer()
    private let content = TaskbarButtonContentView()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    private var downPointInWindow: CGPoint?
    private var beganDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.addSublayer(plateLayer)
        layer?.addSublayer(indicatorLayer)
        indicatorLayer.cornerRadius = 1
        content.button = self
        content.wantsLayer = true
        content.setAccessibilityElement(false)
        addSubview(content)
        content.layer?.zPosition = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        content.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plateLayer.frame = bounds
        plateLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                cornerWidth: TaskbarMetrics.buttonCornerRadius,
                                cornerHeight: TaskbarMetrics.buttonCornerRadius, transform: nil)
        plateLayer.lineWidth = 1
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
        content.needsDisplay = true
    }

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
        updateAppearance(animated: true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateAppearance(animated: true)
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        downPointInWindow = event.locationInWindow
        pressed = true
        beganDrag = false
        updateAppearance(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPointInWindow else { return }
        if !beganDrag {
            let point = event.locationInWindow
            guard hypot(point.x - downPointInWindow.x, point.y - downPointInWindow.y) >= 4 else { return }
            beganDrag = true
            pressed = false
            updateAppearance(animated: true)
            onBeginDrag?(event, downPointInWindow)
        }
        onDragMoved?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldClick = downPointInWindow != nil && !beganDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        if beganDrag { onEndDrag?(event, false) }
        downPointInWindow = nil
        pressed = false
        beganDrag = false
        updateAppearance(animated: true)
        if shouldClick { onClick?() }
    }

    override func cancelOperation(_ sender: Any?) {
        if beganDrag { onEndDrag?(nil, true) }
        downPointInWindow = nil
        pressed = false
        beganDrag = false
        updateAppearance(animated: true)
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else if event.keyCode == 36 || event.keyCode == 49 { onClick?() }
        else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    private func updateAppearance(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let visible = isActiveWindow || hovered || pressed
        let alpha: CGFloat = !visible ? 0 : pressed ? 0.11 : hovered ? 0.09 : 0.065
        let color = NSColor(white: dark ? 1 : 0, alpha: alpha)
        let border = NSColor(white: dark ? 1 : 0, alpha: visible ? (dark ? 0.10 : 0.06) : 0)
        let duration = animated && !reduceMotion() ? TaskbarMotion.buttonTransition : 0
        transition(plateLayer, key: "fillColor", to: color.cgColor, duration: duration)
        transition(plateLayer, key: "strokeColor", to: border.cgColor, duration: duration)
        let width: CGFloat = isActiveWindow ? 16 : 4
        let frame = CGRect(x: TaskbarMetrics.iconInset + (16 - width) / 2, y: 24, width: width, height: 2)
        transition(indicatorLayer, key: "bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)), duration: duration)
        transition(indicatorLayer, key: "position", to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), duration: duration)
        transition(indicatorLayer, key: "backgroundColor",
                   to: (isActiveWindow ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor, duration: duration)
        indicatorLayer.isHidden = isOverflow
        content.needsDisplay = true
    }

    private func transition(_ layer: CALayer, key: String, to value: Any, duration: TimeInterval) {
        let previous = layer.presentation()?.value(forKey: key) ?? layer.value(forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKey: key)
        CATransaction.commit()
        if duration > 0, let previous {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = previous
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        } else { layer.removeAnimation(forKey: key) }
    }

    fileprivate func drawContent() {
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
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(in: CGRect(x: TaskbarMetrics.labelInset,
                                            y: floor((bounds.height - size.height) / 2),
                                            width: max(0, bounds.width - TaskbarMetrics.labelInset - TaskbarMetrics.labelTrailingInset),
                                            height: ceil(size.height)), withAttributes: attributes)
        if isCombined {
            let line = NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 3, y: 3, width: 2, height: 22), xRadius: 1, yRadius: 1)
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            line.fill()
        }
    }
}
