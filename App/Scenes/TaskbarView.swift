import AppKit
import QuartzCore

@MainActor
struct TaskbarViewActions {
    var toggle: (String) -> Void = { _ in }
    var activate: (String) -> Void = { _ in }
    var close: (String) -> Void = { _ in }
    var quit: (TaskbarGroupPresentation) -> Void = { _ in }
    var reorder: (String, String, Bool) -> Void = { _, _, _ in }
    var backgroundMenu: (NSEvent, NSView) -> Void = { _, _ in }
    var popupPresented: (NSPanel) -> Void = { _ in }
}

@MainActor
final class TaskbarView: NSGlassEffectView {
    let taskbarContent: TaskbarContentView

    override init(frame: CGRect) {
        taskbarContent = TaskbarContentView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        style = .regular
        cornerRadius = 0
        tintColor = nil
        contentView = taskbarContent
        taskbarContent.autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class TaskbarContentView: NSView, NSDraggingSource {
    static let groupPasteboardType = NSPasteboard.PasteboardType("io.github.sashokey.properwm.window-group")
    var actions = TaskbarViewActions()
    var iconProvider: (TaskbarWindowPresentation) -> NSImage? = { _ in nil }
    private(set) var groups: [TaskbarGroupPresentation] = []
    private(set) var layoutResult = TaskbarLayoutResult(buttons: [], overflowGroups: [], overflowFrame: nil, combinedGroups: [])
    private(set) var buttonViews: [String: TaskbarButtonView] = [:]
    private(set) var overflowButton: TaskbarButtonView?
    private let popup: any TaskbarPopupPresenting
    private var listGroupID: String?
    private var listSignature: [String] = []
    private weak var windowList: TaskbarWindowListView?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private let delay: TaskbarDelayedAction.Delay
    private let fileHover: TaskbarDelayedAction
    private var draggedGroupID: String?
    private var groupDrag = TaskbarGroupDrag()
    private var suppressClick = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: TaskbarMetrics.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, popup: any TaskbarPopupPresenting = TaskbarPopupController(),
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) }) {
        self.popup = popup
        self.delay = delay
        fileHover = TaskbarDelayedAction(delay: delay)
        super.init(frame: frame)
        registerForDraggedTypes([Self.groupPasteboardType, .fileURL])
        setAccessibilityElement(false)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("ProperWM")
        popup.onPresent = { [weak self] panel in self?.actions.popupPresented(panel) }
        popup.onDismiss = { [weak self] in
            self?.listGroupID = nil
            self?.listSignature = []
            self?.windowList = nil
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        hoverTask?.cancel()
        dismissTask?.cancel()
        fileHover.cancel()
    }

    func update(groups: [TaskbarGroupPresentation]) {
        self.groups = groups
        groupDrag.reconcile(liveGroups: groups.map(\.id))
        if let draggedGroupID, !groups.contains(where: { $0.id == draggedGroupID }) {
            self.draggedGroupID = nil
            groupDrag.cancel()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let font = NSFont.systemFont(ofSize: TaskbarMetrics.fontSize)
        let groupLookup = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let displayed = groupDrag.order(groups.map(\.id)).compactMap { groupLookup[$0] }
        let inputs = displayed.map { group in
            TaskbarLayoutGroup(id: group.id,
                               desiredWidth: TaskbarMetrics.buttonWidth(textWidth: (group.name as NSString).size(withAttributes: [.font: font]).width),
                               windows: group.windows.map {
                TaskbarLayoutWindow(id: $0.id, desiredWidth: TaskbarMetrics.buttonWidth(textWidth: ($0.title as NSString).size(withAttributes: [.font: font]).width))
            })
        }
        let result = TaskbarLayout.resolve(groups: inputs, width: bounds.width)
        let changed = result != layoutResult
        layoutResult = result
        if let listGroupID {
            let liveList = listGroupID == "overflow"
                ? groups.filter { result.overflowGroups.contains($0.id) }.flatMap(\.windows)
                : result.combinedGroups.contains(listGroupID) ? groups.first { $0.id == listGroupID }?.windows ?? [] : []
            if liveList.map(\.id) != listSignature { dismissPopups() }
            else { windowList?.updateTitles(windows: liveList) }
        }
        let liveIDs = Set(result.buttons.map(\.id))
        for id in Array(buttonViews.keys) where !liveIDs.contains(id) { buttonViews.removeValue(forKey: id)?.removeFromSuperview() }
        for layout in result.buttons {
            guard let group = groupLookup[layout.groupID],
                  let item = group.windows.first(where: { layout.windowIDs.contains($0.id) }) else { continue }
            let view: TaskbarButtonView
            if let existing = buttonViews[layout.id] { view = existing }
            else {
                view = TaskbarButtonView(frame: layout.frame)
                buttonViews[layout.id] = view
                addSubview(view)
            }
            view.title = layout.isCombined ? group.name : item.title
            view.image = iconProvider(item)
            view.isCombined = layout.isCombined
            view.isActiveWindow = layout.isCombined ? group.isActive : item.isActive
            view.setAccessibilityHelp(group.name)
            view.onClick = { [weak self] in self?.click(layout.id) }
            view.onContextMenu = { [weak self] event in self?.showContextMenu(buttonID: layout.id, event: event) }
            view.onHover = { [weak self] entered in self?.hover(buttonID: layout.id, entered: entered) }
            view.onBeginDrag = { [weak self] event in self?.beginGroupDrag(layout.groupID, event: event) }
            view.alphaValue = draggedGroupID == layout.groupID ? 0.35 : 1
            if changed && groupDrag.target != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().setFrameSize(layout.frame.size)
                    view.animator().setFrameOrigin(layout.frame.origin)
                }
            } else { view.frame = layout.frame }
        }
        if let frame = result.overflowFrame {
            let view = overflowButton ?? TaskbarButtonView(frame: frame)
            if overflowButton == nil { addSubview(view); overflowButton = view }
            view.frame = frame
            view.isOverflow = true
            view.title = String(localized: "More windows")
            view.onClick = { [weak self] in self?.showOverflow() }
        } else { overflowButton?.removeFromSuperview(); overflowButton = nil }
    }

    private func click(_ id: String) {
        guard !suppressClick,
              let button = layoutResult.buttons.first(where: { $0.id == id }),
              let group = groups.first(where: { $0.id == button.groupID }) else { return }
        if button.isCombined { showWindowList(group: group, anchor: button.frame) }
        else if let item = group.windows.first(where: { button.windowIDs.contains($0.id) }) {
            dismissPopups()
            actions.toggle(item.item.actionWindowID)
        }
    }

    private func hover(buttonID: String, entered: Bool) {
        guard draggedGroupID == nil else { return }
        hoverTask?.cancel()
        if entered {
            guard layoutResult.buttons.first(where: { $0.id == buttonID })?.isCombined == true else {
                scheduleDismiss()
                return
            }
            dismissTask?.cancel()
            let delay = delay
            hoverTask = Task { @MainActor [weak self] in
                await delay(.milliseconds(400))
                guard !Task.isCancelled, let self,
                      let layout = self.layoutResult.buttons.first(where: { $0.id == buttonID }), layout.isCombined,
                      let group = self.groups.first(where: { $0.id == layout.groupID }) else { return }
                self.showWindowList(group: group, anchor: layout.frame)
            }
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let delay = delay
        dismissTask = Task { @MainActor [weak self] in
            await delay(.milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if let panel = self.popup.panel, panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { return }
            self.dismissPopups()
        }
    }

    func dismissPopups() {
        hoverTask?.cancel()
        dismissTask?.cancel()
        popup.dismiss()
    }

    func prepareForHiding() {
        dismissPopups()
        cancelFileHover()
        groupDrag.cancel()
        draggedGroupID = nil
        suppressClick = false
        needsLayout = true
    }

    private func screenAnchor(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func showWindowList(group: TaskbarGroupPresentation, anchor: CGRect) {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        dismissTask?.cancel()
        if listGroupID == group.id && listSignature == group.windows.map(\.id) && popup.isPresented { return }
        let view = TaskbarWindowListView(windows: group.windows,
                                      availableHeight: screen.visibleFrame.height - TaskbarMetrics.height - 24,
                                      delay: delay,
                                      icon: iconProvider,
                                      activate: { [weak self] item in self?.activateIfLive(item, dismiss: true) },
                                      close: { [weak self] item in self?.closeIfLive(item.item.actionWindowID) },
                                      fileHover: { [weak self] item in self?.activateIfLive(item, dismiss: false) })
        let frame = TaskbarPopupGeometry.frame(anchor: screenAnchor(anchor), contentSize: view.frame.size, screen: screen.frame)
        popup.present(content: view, frame: frame, anchorWindow: window)
        windowList = view
        listGroupID = group.id
        listSignature = group.windows.map(\.id)
        view.onHover = { [weak self] entered in
            if entered { self?.dismissTask?.cancel() }
            else { self?.scheduleDismiss() }
        }
    }

    private func showOverflow() {
        guard let anchor = layoutResult.overflowFrame else { return }
        let ids = Set(layoutResult.overflowGroups)
        let windows = groups.filter { ids.contains($0.id) }.flatMap(\.windows)
        showWindowList(group: TaskbarGroupPresentation(id: "overflow", name: String(localized: "More windows"), windows: windows),
                    anchor: anchor)
    }

    private func showContextMenu(buttonID: String, event: NSEvent) {
        guard let button = layoutResult.buttons.first(where: { $0.id == buttonID }),
              let group = groups.first(where: { $0.id == button.groupID }),
              let screen = window?.screen ?? NSScreen.main else { return }
        dismissPopups()
        let entries = TaskbarContextMenuModel.actions(button: button, group: group).map { action in
            switch action {
            case let .closeWindow(id):
                return TaskbarMenuEntry(title: String(localized: "Close window"), symbol: "xmark", action: { [weak self] in self?.closeIfLive(id) })
            case let .closeWindows(ids):
                return TaskbarMenuEntry(title: String(localized: "Close all windows"), symbol: "xmark", action: { [weak self] in
                    for id in ids { self?.closeIfLive(id) }
                })
            case .quitApplication:
                return TaskbarMenuEntry(title: String(localized: "Quit"), symbol: "power", action: { [weak self] in
                    guard let self, let current = self.groups.first(where: { $0.id == group.id }) else { return }
                    let originalPIDs = Set(group.windows.map(\.item.pid))
                    let survivors = current.windows.filter { originalPIDs.contains($0.item.pid) }
                    guard !survivors.isEmpty else { return }
                    self.actions.quit(TaskbarGroupPresentation(id: current.id, name: current.name, windows: survivors))
                })
            }
        }
        let view = TaskbarMenuView(entries: entries) { [weak self] in self?.dismissPopups() }
        let frame = TaskbarPopupGeometry.frame(anchor: screenAnchor(button.frame), contentSize: view.frame.size, screen: screen.frame)
        popup.present(content: view, frame: frame, anchorWindow: window)
    }

    override func rightMouseDown(with event: NSEvent) {
        dismissPopups()
        actions.backgroundMenu(event, self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { dismissPopups() }
    }

    private func beginGroupDrag(_ id: String, event: NSEvent) {
        guard let group = groups.first(where: { $0.id == id }), !group.windows.isEmpty else { return }
        dismissPopups()
        let rectangles = layoutResult.buttons.filter { $0.groupID == id }.map(\.frame)
        guard let first = rectangles.first else { return }
        let frame = rectangles.dropFirst().reduce(first) { $0.union($1) }
        guard let bitmap = bitmapImageRepForCachingDisplay(in: frame) else { return }
        cacheDisplay(in: frame, to: bitmap)
        let image = NSImage(size: frame.size)
        image.addRepresentation(bitmap)
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(id, forType: Self.groupPasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(frame, contents: image)
        draggedGroupID = id
        suppressClick = true
        needsLayout = true
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedGroupID = nil
        groupDrag.cancel()
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.suppressClick = false }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if let id = sender.draggingPasteboard.string(forType: Self.groupPasteboardType) {
            guard sender.draggingSource is TaskbarContentView, groups.contains(where: { $0.id == id }) else { return [] }
            let targets = layoutResult.buttons.filter { $0.groupID != id }
            guard let target = targets.first(where: { $0.frame.contains(point) }) else { return .move }
            let groupFrame = targets.filter { $0.groupID == target.groupID }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let after = point.x > groupFrame.midX
            groupDrag.update(groupID: id, target: target.groupID, after: after, liveGroups: groups.map(\.id))
            needsLayout = true

            return .move
        }
        if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
           let frame = layoutResult.overflowFrame, frame.contains(point) {
            fileHover.schedule(target: "overflow", after: .milliseconds(600)) { [weak self] in self?.showOverflow() }
            return .generic
        }
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
              let button = layoutResult.buttons.first(where: { $0.frame.contains(point) }),
              groups.contains(where: { $0.id == button.groupID }) else {
            cancelFileHover()
            return []
        }
        scheduleFileHover(buttonID: button.id)

        return .generic
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cancelFileHover()
        if listGroupID != nil { scheduleDismiss() }
        groupDrag.cancel()
        needsLayout = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        cancelFileHover()
        guard let id = sender.draggingPasteboard.string(forType: Self.groupPasteboardType),
              sender.draggingSource is TaskbarContentView,
              let target = groupDrag.target, groupDrag.groupID == id,
              groups.contains(where: { $0.id == id }),
              groups.contains(where: { $0.id == target.groupID }) else { return false }
        actions.reorder(id, target.groupID, target.after)
        groupDrag.cancel()
        return true
    }

    func scheduleFileHover(buttonID: String) {
        fileHover.schedule(target: buttonID, after: .milliseconds(600)) { [weak self] in
            guard let self,
                  let button = self.layoutResult.buttons.first(where: { $0.id == buttonID }),
                  let group = self.groups.first(where: { $0.id == button.groupID }) else { return }
            if button.isCombined { self.showWindowList(group: group, anchor: button.frame) }
            else if let item = group.windows.first(where: { button.windowIDs.contains($0.id) }) {
                self.activateIfLive(item, dismiss: true)
            }
        }
    }

    private func activateIfLive(_ item: TaskbarWindowPresentation, dismiss: Bool) {
        guard groups.flatMap(\.windows).contains(where: { $0.id == item.id && $0.item.actionWindowID == item.item.actionWindowID }) else { return }
        if dismiss { dismissPopups() }
        actions.activate(item.item.actionWindowID)
    }

    private func closeIfLive(_ id: String) {
        guard groups.flatMap(\.windows).contains(where: { $0.item.actionWindowID == id && $0.item.canClose }) else { return }
        actions.close(id)
    }

    private func cancelFileHover() {
        fileHover.cancel()
    }
}
