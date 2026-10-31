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
    func focusForKeyboard()
    func dismiss()
}

@MainActor
final class TaskbarPopupController: TaskbarPopupPresenting {
    private(set) var panel: NSPanel?
    var isPresented: Bool { panel != nil }
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let makePanel: (CGRect) -> NSPanel
    private let monitorsOutsideEvents: Bool
    var onPresent: ((NSPanel) -> Void)?
    var onDismiss: (() -> Void)?

    init(makePanel: ((CGRect) -> NSPanel)? = nil, monitorsOutsideEvents: Bool = true) {
        self.makePanel = makePanel ?? {
            TaskbarPopupPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
        self.monitorsOutsideEvents = monitorsOutsideEvents
    }

    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
        dismiss()
        let panel = makePanel(frame)
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
        (content as? TaskbarWindowListView)?.onCancel = { [weak self] in self?.dismiss() }
        self.panel = panel
        panel.orderFrontRegardless()
        onPresent?(panel)
        guard monitorsOutsideEvents else { return }
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

    func focusForKeyboard() {
        guard let panel, let content = panel.contentView else { return }
        panel.makeKey()
        panel.makeFirstResponder(content)
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
private final class TaskbarMenuAction: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    @objc func invokeMenuItem(_ sender: NSMenuItem) { action() }
}

@MainActor
enum TaskbarNativeMenuFactory {
    static func menu(entries: [TaskbarMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries { menu.addItem(item(entry)) }
        return menu
    }

    static func statusMenu(launchAtLogin: NSMenuItem, hideStatusBarIcon: NSMenuItem, quit: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(launchAtLogin)
        menu.addItem(hideStatusBarIcon)
        menu.addItem(.separator())
        menu.addItem(item(TaskbarMenuEntry(title: String(localized: "Quit"), symbol: "", action: quit)))
        return menu
    }

    private static func item(_ entry: TaskbarMenuEntry) -> NSMenuItem {
        let target = TaskbarMenuAction(action: entry.action)
        let item = NSMenuItem(title: entry.title, action: #selector(TaskbarMenuAction.invokeMenuItem(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        if !entry.symbol.isEmpty {
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        }
        return item
    }
}

@MainActor
protocol TaskbarContextMenuPresenting: AnyObject {
    var visibilityChanged: ((Bool) -> Void)? { get set }
    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView)
    func dismiss()
}

@MainActor
final class TaskbarNativeContextMenu: TaskbarContextMenuPresenting {
    var visibilityChanged: ((Bool) -> Void)?
    private var menu: NSMenu?

    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) {
        dismiss()
        let menu = TaskbarNativeMenuFactory.menu(entries: entries)
        self.menu = menu
        visibilityChanged?(true)
        defer {
            self.menu = nil
            visibilityChanged?(false)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func dismiss() { menu?.cancelTrackingWithoutAnimation() }
}

@MainActor
private final class TaskbarWindowTable: NSTableView {
    var handleKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class TaskbarWindowListView: NSGlassEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var cells: [TaskbarWindowListRow] = []
    let tableView: NSTableView = TaskbarWindowTable()
    let scrollView = NSScrollView()
    var onHover: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }

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
        style = .regular
        cornerRadius = 4
        tintColor = nil
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        tableView.frame = CGRect(x: 0, y: 0, width: size.width, height: cellHeight * CGFloat(windows.count))
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = .zero
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = cellHeight
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.width = size.width
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateSelectedWindow)
        (tableView as? TaskbarWindowTable)?.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        for (index, item) in windows.enumerated() {
            let cell = TaskbarWindowListRow(window: item, icon: icon(item), delay: delay,
                                          activate: { activate(item) }, close: { close(item) },
                                          fileHover: { fileHover(item) })
            cell.onDragPresence = { [weak self] inside in self?.onHover?(inside) }
            cell.onHighlightChanged = { [weak self] selected in
                self?.tableView.rowView(atRow: index, makeIfNecessary: false)?.isSelected = selected
            }
            cells.append(cell)
        }
        scrollView.documentView = tableView
        contentView = scrollView
        tableView.reloadData()
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { cells.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { cells[row] }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.backgroundColor = .clear
        view.isEmphasized = false
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for (index, cell) in cells.enumerated() { cell.keyboardSelected = tableView.selectedRowIndexes.contains(index) }
    }

    @objc private func activateSelectedWindow() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        if cells.indices.contains(index) { cells[index].activate() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !cells.isEmpty else { return false }
        switch event.keyCode {
        case 53:
            onCancel?()
            return true
        case 125, 126:
            let delta = event.keyCode == 125 ? 1 : -1
            let selected = tableView.selectedRow
            let index = selected >= 0 ? (selected + delta + cells.count) % cells.count : (delta > 0 ? 0 : cells.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            return true
        case 36, 49:
            let index = tableView.selectedRow
            if cells.indices.contains(index) { cells[index].activate() }
            return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
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
final class TaskbarWindowListRow: NSTableCellView {
    let item: TaskbarWindowPresentation
    var title: String {
        didSet {
            textField?.stringValue = title
            setAccessibilityLabel(title)
        }
    }
    let icon: NSImage?
    let activate: () -> Void
    let close: () -> Void
    let fileHover: () -> Void
    let closeButton = NSButton()
    var onDragPresence: ((Bool) -> Void)?
    var onHighlightChanged: ((Bool) -> Void)?
    private var hovered = false
    var keyboardSelected = false { didSet { updateHighlight() } }
    private var tracking: NSTrackingArea?
    private let delayedActivation: TaskbarDelayedAction
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        super.init(frame: CGRect(x: 0, y: 0, width: TaskbarMetrics.windowListWidth, height: TaskbarMetrics.windowListRowHeight))
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        imageView = iconView
        addSubview(iconView)
        let label = NSTextField(labelWithString: window.title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        textField = label
        addSubview(label)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.controlSize = .small
        closeButton.showsBorderOnlyWhileMouseInside = true
        closeButton.tintProminence = .none
        closeButton.isHidden = true
        closeButton.setAccessibilityLabel(String(localized: "Close window"))
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(window.title)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Close window"), handler: { close(); return true })])
        registerForDraggedTypes([.fileURL])
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { delayedActivation.cancel() }

    override func layout() {
        super.layout()
        imageView?.frame = CGRect(x: 8, y: 12, width: 16, height: 16)
        if let textField {
            textField.frame = textField.frame(forAlignmentRect: CGRect(x: 32, y: 12, width: max(0, bounds.width - 68), height: 20))
        }
        closeButton.frame = CGRect(x: bounds.width - 36, y: 4, width: 32, height: 32)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateHighlight() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHighlight() }
    override func accessibilityPerformPress() -> Bool { activate(); return true }

    private func updateHighlight() {
        let selected = hovered || keyboardSelected
        closeButton.isHidden = !selected
        onHighlightChanged?(selected)
    }

    @objc private func closeWindow() { close() }

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
}
