import AppKit

private enum StatusMenuLayout {
    static let textInsetX: CGFloat = 28
    static let trailingInsetX: CGFloat = 14
}

@MainActor
final class TaskbarSizeMenuItemView: NSView {
    var onEditingChanged: ((Bool) -> Void)?
    var onHeightChange: ((DockPanelHeight) -> Void)?

    private let titleLabel = NSTextField(labelWithString: String(localized: "Taskbar Size"))
    private let smallLabel = NSTextField(labelWithString: String(localized: "Small"))
    private let largeLabel = NSTextField(labelWithString: String(localized: "Large"))
    private let slider = MenuTrackingSlider()

    init(accessibilityTitle: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        autoresizingMask = [.width]

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        for label in [smallLabel, largeLabel] {
            label.font = .systemFont(ofSize: 9)
            label.textColor = NSColor.secondaryLabelColor
            label.alignment = .center
            label.setAccessibilityElement(false)
            addSubview(label)
        }

        slider.minValue = Double(DockPanelHeight.minimum)
        slider.maxValue = Double(DockPanelHeight.maximum)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onTrackingStarted = { [weak self] in self?.onEditingChanged?(true) }
        slider.onTrackingEnded = { [weak self] in self?.onEditingChanged?(false) }
        slider.setAccessibilityLabel(accessibilityTitle)
        addSubview(slider)
        sync(height: .default)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let width = window?.frame.width, width > frame.width {
            frame.size.width = width
        }
    }

    func sync(height: DockPanelHeight) {
        slider.doubleValue = Double(height.points)
        slider.displayString = "\(Int(height.points))"
    }

    override func layout() {
        super.layout()
        let contentX = StatusMenuLayout.textInsetX
        let contentWidth = bounds.width - contentX - StatusMenuLayout.trailingInsetX
        let labelWidth = max(smallLabel.intrinsicContentSize.width, largeLabel.intrinsicContentSize.width)
        let sideInset = max(34, ceil(labelWidth) + 6)
        titleLabel.frame = NSRect(x: contentX, y: bounds.height - 24, width: contentWidth, height: 18)
        let sliderY: CGFloat = 8
        slider.frame = NSRect(x: contentX + sideInset, y: sliderY, width: max(0, contentWidth - sideInset * 2), height: 20)
        let labelY: CGFloat = 12
        smallLabel.frame = NSRect(x: contentX, y: labelY, width: sideInset, height: 12)
        largeLabel.frame = NSRect(x: slider.frame.maxX, y: labelY, width: sideInset, height: 12)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let height = DockPanelHeight(clamping: CGFloat(sender.doubleValue))
        slider.displayString = "\(Int(height.points))"
        onHeightChange?(height)
    }
}

final class MenuTrackingSlider: NSSlider {
    var displayString = "0.0s"
    var onTrackingStarted: (() -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var isMouseTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isMouseTracking = true
        onTrackingStarted?()
        super.mouseDown(with: event)
        isMouseTracking = false
        onTrackingEnded?()
    }

    override func accessibilityValue() -> Any? {
        displayString
    }
}
