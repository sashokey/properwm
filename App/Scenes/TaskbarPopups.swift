import AppKit

struct TaskbarMenuEntry {
    let title: String
    let symbol: String
    let action: @MainActor () -> Void
}

@MainActor
private final class TaskbarPopupPanel: NonConstrainingPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol TaskbarPopupPresenting: AnyObject {
    var panel: NSPanel? { get }
    var isPresented: Bool { get }
    var onPresent: ((NSPanel) -> Void)? { get set }
    var onDismiss: (() -> Void)? { get set }
    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?)
    func dismiss()
}

@MainActor
final class TaskbarPopupController: TaskbarPopupPresenting {
    private(set) var panel: NSPanel?
    var isPresented: Bool { panel != nil }
    private var localMonitor: Any?
    private var globalMonitor: Any?
    var onPresent: ((NSPanel) -> Void)?
    var onDismiss: (() -> Void)?

    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
        dismiss()
        let panel = TaskbarPopupPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.appearance = anchorWindow?.effectiveAppearance
        content.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = content
        panel.makeFirstResponder(content)
        self.panel = panel
        panel.orderFrontRegardless()
        onPresent?(panel)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown, event.keyCode == 53 { self.dismiss(); return true }
                if event.type != .keyDown, event.window !== self.panel,
                   !frame.contains(NSEvent.mouseLocation) { self.dismiss() }
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let panel {
            (panel.contentView as? TaskbarWindowListView)?.cancelPendingActions()
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel = nil
        onDismiss?()
    }

    isolated deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        panel?.orderOut(nil)
    }
}

@MainActor
final class TaskbarMenuView: NSView {
    static let width: CGFloat = 294
    static let rowHeight: CGFloat = 32

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var selectedIndex: Int?
    private var rows: [TaskbarMenuRow] = []

    init(entries: [TaskbarMenuEntry], dismiss: @escaping () -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: CGFloat(entries.count) * Self.rowHeight + 4))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        setAccessibilityElement(false)
        setAccessibilityRole(.menu)
        for (index, entry) in entries.enumerated() {
            let row = TaskbarMenuRow(entry: entry) { dismiss(); entry.action() }
            row.frame = CGRect(x: 4, y: 2 + CGFloat(index) * Self.rowHeight,
                               width: Self.width - 8, height: Self.rowHeight)
            addSubview(row)
            rows.append(row)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { updateColors() }

    override func keyDown(with event: NSEvent) {
        guard !rows.isEmpty else { return }
        switch event.keyCode {
        case 125, 126:
            let delta = event.keyCode == 125 ? 1 : -1
            let index = selectedIndex.map { ($0 + delta + rows.count) % rows.count } ?? (delta > 0 ? 0 : rows.count - 1)
            selectedIndex = index
            for (i, row) in rows.enumerated() { row.keyboardSelected = i == index }
        case 36, 49:
            if let selectedIndex { rows[selectedIndex].action() }
        default: super.keyDown(with: event)
        }
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor(white: dark ? 0.165 : 0.98, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: dark ? 0 : 0.75, alpha: 0.35).cgColor
    }
}

@MainActor
private final class TaskbarMenuRow: NSView {
    let entry: TaskbarMenuEntry
    let action: () -> Void
    private var hovered = false
    var keyboardSelected = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(entry: TaskbarMenuEntry, action: @escaping () -> Void) {
        self.entry = entry
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(entry.title)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { action() }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || keyboardSelected {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        if let symbol = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            symbol.withSymbolConfiguration(configuration)?.draw(in: CGRect(x: 12, y: 8, width: 16, height: 16),
                                                                 from: .zero, operation: .sourceOver, fraction: 1,
                                                                 respectFlipped: true, hints: nil)
        }
        (entry.title as NSString).draw(at: CGPoint(x: 40, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
    }
}

@MainActor
final class TaskbarWindowListView: NSView {
    private(set) var cells: [TaskbarWindowListRow] = []
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var selectedIndex: Int?

    init(windows: [TaskbarWindowPresentation], availableHeight: CGFloat,
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) },
         icon: @escaping (TaskbarWindowPresentation) -> NSImage?,
         activate: @escaping (TaskbarWindowPresentation) -> Void,
         close: @escaping (TaskbarWindowPresentation) -> Void,
         fileHover: @escaping (TaskbarWindowPresentation) -> Void) {
        let cellHeight = TaskbarMetrics.windowListRowHeight
        let size = CGSize(width: TaskbarMetrics.windowListWidth,
                          height: min(max(cellHeight, availableHeight), cellHeight * CGFloat(windows.count)))
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        let flipped = TaskbarFlippedView(frame: CGRect(x: 0, y: 0, width: size.width,
                                                      height: cellHeight * CGFloat(windows.count)))
        for (index, item) in windows.enumerated() {
            let cell = TaskbarWindowListRow(window: item, icon: icon(item), delay: delay,
                                          activate: { activate(item) }, close: { close(item) },
                                          fileHover: { fileHover(item) })
            cell.onDragPresence = { [weak self] inside in self?.onHover?(inside) }
            cell.frame = CGRect(x: 0,
                                y: CGFloat(index) * cellHeight,
                                width: TaskbarMetrics.windowListWidth, height: cellHeight)
            flipped.addSubview(cell)
            cells.append(cell)
        }
        if flipped.frame.height > size.height {
            let scroll = NSScrollView(frame: bounds)
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = flipped
            addSubview(scroll)
        } else { addSubview(flipped) }
    }

    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        guard !cells.isEmpty else { return }
        switch event.keyCode {
        case 125, 126:
            let delta = event.keyCode == 125 ? 1 : -1
            let index = selectedIndex.map { ($0 + delta + cells.count) % cells.count } ?? (delta > 0 ? 0 : cells.count - 1)
            selectedIndex = index
            for (i, cell) in cells.enumerated() { cell.keyboardSelected = i == index }
            cells[index].scrollToVisible(cells[index].bounds)
        case 36, 49:
            if let selectedIndex { cells[selectedIndex].activate() }
        default: super.keyDown(with: event)
        }
    }

    func cancelPendingActions() {
        for cell in cells { cell.cancelFileHover() }
    }

    func updateTitles(windows: [TaskbarWindowPresentation]) {
        let titles = Dictionary(windows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for cell in cells {
            if let title = titles[cell.item.id] { cell.title = title }
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
private final class TaskbarFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class TaskbarWindowListRow: NSView {
    let item: TaskbarWindowPresentation
    var title: String { didSet { setAccessibilityLabel(title); needsDisplay = true } }
    let icon: NSImage?
    let activate: () -> Void
    let close: () -> Void
    let fileHover: () -> Void
    var onDragPresence: ((Bool) -> Void)?
    private var hovered = false
    var keyboardSelected = false { didSet { needsDisplay = true } }
    private var closeHovered = false
    private var tracking: NSTrackingArea?
    private let delayedActivation: TaskbarDelayedAction
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var closeFrame: CGRect { CGRect(x: bounds.width - 36, y: 4, width: 32, height: 32) }

    init(window: TaskbarWindowPresentation, icon: NSImage?,
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) },
         activate: @escaping () -> Void, close: @escaping () -> Void, fileHover: @escaping () -> Void) {
        delayedActivation = TaskbarDelayedAction(delay: delay)
        self.item = window
        self.title = window.title
        self.icon = icon
        self.activate = activate
        self.close = close
        self.fileHover = fileHover
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(window.title)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Close window"), handler: { close(); return true })])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { delayedActivation.cancel() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; closeHovered = false; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        closeHovered = closeFrame.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if closeFrame.contains(point) { close() } else { activate() }
    }
    override func accessibilityPerformPress() -> Bool { activate(); return true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        onDragPresence?(true)
        scheduleFileHover()
        return .generic
    }

    func scheduleFileHover() {
        delayedActivation.schedule(target: item.id, after: .milliseconds(600)) { [weak self] in self?.fileHover() }
    }

    func cancelFileHover() { delayedActivation.cancel() }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { cancelFileHover(); onDragPresence?(false) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        cancelFileHover()
        onDragPresence?(false)
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlighted = hovered || keyboardSelected
        NSColor(white: dark ? (highlighted ? 0.23 : 0.17) : (highlighted ? 0.94 : 0.98), alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        icon?.draw(in: CGRect(x: 8, y: 12, width: 16, height: 16), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: CGRect(x: 32, y: 12, width: bounds.width - 68, height: 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        if hovered {
            if closeHovered {
                NSColor(red: 0.77, green: 0.17, blue: 0.11, alpha: 1).setFill()
                NSBezierPath(roundedRect: closeFrame, xRadius: 4, yRadius: 4).fill()
            }
            let cross = NSBezierPath()
            let center = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
            cross.move(to: CGPoint(x: center.x - 5, y: center.y - 5))
            cross.line(to: CGPoint(x: center.x + 5, y: center.y + 5))
            cross.move(to: CGPoint(x: center.x + 5, y: center.y - 5))
            cross.line(to: CGPoint(x: center.x - 5, y: center.y + 5))
            (closeHovered ? NSColor.white : NSColor.labelColor).setStroke()
            cross.lineWidth = 1
            cross.stroke()
        }
    }
}
