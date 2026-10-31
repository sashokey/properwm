import AppKit

@MainActor
final class TaskbarButtonView: NSButton {
    override var title: String {
        didSet {
            titleLabel.stringValue = title
            setAccessibilityLabel(title)
        }
    }
    override var image: NSImage? { didSet { iconView.image = image } }
    var isActiveWindow = false { didSet { if oldValue != isActiveWindow { updateAppearance(animated: true) } } }
    var isCombined = false { didSet { groupIndicator.isHidden = !isCombined } }
    var isOverflow = false {
        didSet {
            if isOverflow { image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil) }
            titleLabel.isHidden = isOverflow
            indicator.isHidden = isOverflow
            needsLayout = true
        }
    }
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onBeginDrag: ((NSEvent, CGPoint) -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onEndDrag: ((NSEvent?, Bool) -> Void)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    let selectionView = NSBox()
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let indicator = NSBox()
    private let groupIndicator = NSBox()
    private var tracking: NSTrackingArea?
    private var downPointInWindow: CGPoint?
    private var beganDrag = false
    private var hovered = false
    private var pressed = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        isBordered = false
        isTransparent = true
        tintProminence = .none
        target = self
        action = #selector(activateButton)
        wantsLayer = true
        selectionView.wantsLayer = true
        selectionView.boxType = .custom
        selectionView.titlePosition = .noTitle
        selectionView.borderWidth = 0
        selectionView.cornerRadius = TaskbarMetrics.buttonCornerRadius
        selectionView.contentViewMargins = .zero
        selectionView.fillColor = .unemphasizedSelectedContentBackgroundColor
        selectionView.alphaValue = 0
        selectionView.setAccessibilityElement(false)
        addSubview(selectionView)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        titleLabel.font = NSFont.systemFont(ofSize: TaskbarMetrics.fontSize)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
        indicator.wantsLayer = true
        indicator.boxType = .custom
        indicator.titlePosition = .noTitle
        indicator.borderWidth = 0
        indicator.cornerRadius = 1
        indicator.contentViewMargins = .zero
        indicator.setAccessibilityElement(false)
        addSubview(indicator)
        groupIndicator.boxType = .separator
        groupIndicator.isHidden = true
        groupIndicator.setAccessibilityElement(false)
        addSubview(groupIndicator)
        title = ""
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        selectionView.frame = bounds
        let iconX = isOverflow ? floor((bounds.width - TaskbarMetrics.iconSize) / 2) : TaskbarMetrics.iconInset
        iconView.frame = CGRect(x: iconX, y: 6, width: TaskbarMetrics.iconSize, height: TaskbarMetrics.iconSize)
        let font = titleLabel.font ?? NSFont.systemFont(ofSize: TaskbarMetrics.fontSize)
        let height = ceil((title as NSString).size(withAttributes: [.font: font]).height)
        let titleRect = CGRect(x: TaskbarMetrics.labelInset, y: floor((bounds.height - height) / 2),
                               width: max(0, bounds.width - TaskbarMetrics.labelInset - TaskbarMetrics.labelTrailingInset), height: height)
        titleLabel.frame = titleLabel.frame(forAlignmentRect: titleRect)
        if indicator.frame != indicatorFrame { indicator.frame = indicatorFrame }
        groupIndicator.frame = CGRect(x: bounds.maxX - 3, y: 3, width: 2, height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true
        updateAppearance(animated: true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false
        updateAppearance(animated: true)
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        downPointInWindow = event.locationInWindow
        beganDrag = false
        pressed = true
        highlight(true)
        updateAppearance(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPointInWindow else { return }
        if !beganDrag {
            let point = event.locationInWindow
            guard hypot(point.x - downPointInWindow.x, point.y - downPointInWindow.y) >= 4 else { return }
            beganDrag = true
            pressed = false
            highlight(false)
            updateAppearance(animated: true)
            onBeginDrag?(event, downPointInWindow)
        }
        onDragMoved?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldClick = downPointInWindow != nil && !beganDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        if beganDrag { onEndDrag?(event, false) }
        downPointInWindow = nil
        beganDrag = false
        pressed = false
        highlight(false)
        updateAppearance(animated: true)
        if shouldClick { activateButton() }
    }

    override func cancelOperation(_ sender: Any?) {
        if beganDrag { onEndDrag?(nil, true) }
        downPointInWindow = nil
        beganDrag = false
        pressed = false
        highlight(false)
        updateAppearance(animated: true)
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else if event.keyCode == 36 || event.keyCode == 49 { performClick(nil) }
        else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, onClick != nil else { return false }
        activateButton()
        return true
    }

    @objc private func activateButton() {
        guard isEnabled else { return }
        onClick?()
        state = isActiveWindow ? .on : .off
    }

    private var indicatorFrame: CGRect {
        let width: CGFloat = isActiveWindow ? 16 : 4
        return CGRect(x: TaskbarMetrics.iconInset + (16 - width) / 2, y: 24, width: width, height: 2)
    }

    private func updateAppearance(animated: Bool) {
        state = isActiveWindow ? .on : .off
        let opacity: CGFloat = pressed ? 1 : hovered ? 0.9 : isActiveWindow ? 0.65 : 0
        selectionView.fillColor = .unemphasizedSelectedContentBackgroundColor
        indicator.fillColor = isActiveWindow ? .controlAccentColor : .secondaryLabelColor
        let duration = animated && !reduceMotion() ? TaskbarMotion.buttonTransition : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            if duration > 0 {
                selectionView.animator().alphaValue = opacity
                indicator.animator().frame = indicatorFrame
            } else {
                selectionView.alphaValue = opacity
                indicator.frame = indicatorFrame
            }
        }
    }
}
