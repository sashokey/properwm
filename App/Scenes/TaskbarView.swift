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
    var contextMenuVisibilityChanged: (Bool) -> Void = { _ in }
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
final class TaskbarContentView: NSView {
    var actions = TaskbarViewActions()
    var iconProvider: (TaskbarWindowPresentation) -> NSImage? = { _ in nil }
    private(set) var groups: [TaskbarGroupPresentation] = []
    private(set) var layoutResult = TaskbarLayoutResult(buttons: [], overflowGroups: [], overflowFrame: nil, combinedGroups: [])
    private(set) var buttonViews: [String: TaskbarButtonView] = [:]
    private(set) var overflowButton: TaskbarButtonView?
    private let popup: any TaskbarPopupPresenting
    private let contextMenu: any TaskbarContextMenuPresenting
    private var listGroupID: String?
    private var listSignature: [String] = []
    private weak var windowList: TaskbarWindowListView?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private let delay: TaskbarDelayedAction.Delay
    private let fileHover: TaskbarDelayedAction
    private var draggedGroupID: String?
    private var dragMembers: [String] = []
    private var dragButtonIDs = Set<String>()
    private var dragGeometry: TaskbarDragGeometry?
    private var dragPointer = CGPoint.zero
    private var animateNextLayout = false
    private var localDragMonitor: Any?
    private var globalDragMonitor: Any?
    private var groupDrag = TaskbarGroupDrag()
    private var suppressClick = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: TaskbarMetrics.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, popup: any TaskbarPopupPresenting = TaskbarPopupController(),
         contextMenu: any TaskbarContextMenuPresenting = TaskbarNativeContextMenu(),
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) }) {
        self.popup = popup
        self.contextMenu = contextMenu
        self.delay = delay
        fileHover = TaskbarDelayedAction(delay: delay)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("ProperWM")
        contextMenu.visibilityChanged = { [weak self] visible in self?.actions.contextMenuVisibilityChanged(visible) }
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
        if let localDragMonitor { NSEvent.removeMonitor(localDragMonitor) }
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor) }
    }

    func update(groups: [TaskbarGroupPresentation]) {
        self.groups = groups
        groupDrag.reconcile(liveGroups: groups.map(\.id))
        if let draggedGroupID, groups.first(where: { $0.id == draggedGroupID })?.windows.map(\.id) != dragMembers {
            endGroupDrag(event: nil, cancelled: true)
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
        var result = TaskbarLayout.resolve(groups: inputs, width: bounds.width)
        if let draggedGroupID,
           Set(result.buttons.filter { $0.groupID == draggedGroupID }.map(\.id)) != dragButtonIDs {
            endGroupDrag(event: nil, cancelled: true)
            let inputLookup = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result = TaskbarLayout.resolve(groups: groups.compactMap { inputLookup[$0.id] }, width: bounds.width)
        }
        let changed = result != layoutResult
        layoutResult = result
        if let listGroupID {
            let liveList = listGroupID == "overflow"
                ? groups.filter { result.overflowGroups.contains($0.id) }.flatMap(\.windows)
                : result.combinedGroups.contains(listGroupID) ? groups.first { $0.id == listGroupID }?.windows ?? [] : []
            if liveList.map(\.id) != listSignature { dismissPopups() }
            else { windowList?.updateTitles(windows: liveList) }
        }
        let animateLayout = animateNextLayout || (changed && draggedGroupID != nil)
        animateNextLayout = false
        let dragFrames = dragFrames(in: result)
        let liveIDs = Set(result.buttons.map(\.id))
        for id in Array(buttonViews.keys) where !liveIDs.contains(id) { buttonViews.removeValue(forKey: id)?.removeFromSuperview() }
        for layout in result.buttons {
            guard let group = groupLookup[layout.groupID],
                  let item = group.windows.first(where: { layout.windowIDs.contains($0.id) }) else { continue }
            let frame = interactionFrame(for: layout.frame)
            let view: TaskbarButtonView
            if let existing = buttonViews[layout.id] { view = existing }
            else {
                view = TaskbarButtonView(frame: frame)
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
            view.onBeginDrag = { [weak self] event, start in self?.beginGroupDrag(layout.groupID, event: event, start: start) }
            view.onDragMoved = { [weak self] event in self?.moveGroupDrag(event: event) }
            view.onEndDrag = { [weak self] event, cancelled in self?.endGroupDrag(event: event, cancelled: cancelled) }
            view.alphaValue = 1
            view.layer?.zPosition = draggedGroupID == layout.groupID ? 1 : 0
            if draggedGroupID == layout.groupID, let dragFrames {
                view.layer?.removeAllAnimations()
                view.frame = frame.offsetBy(dx: dragFrames.displayed.minX - dragFrames.slot.minX, dy: 0)
            } else if animateLayout && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = TaskbarMotion.reorderTransition
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().setFrameSize(frame.size)
                    view.animator().setFrameOrigin(frame.origin)
                }
            } else { view.frame = frame }
        }
        if let overflowFrame = result.overflowFrame {
            let frame = interactionFrame(for: overflowFrame)
            let view = overflowButton ?? TaskbarButtonView(frame: frame)
            if overflowButton == nil { addSubview(view); overflowButton = view }
            view.frame = frame
            view.isOverflow = true
            view.title = String(localized: "More windows")
            view.onClick = { [weak self] in self?.showOverflow(focusForKeyboard: true) }
        } else { overflowButton?.removeFromSuperview(); overflowButton = nil }
    }

    private func interactionFrame(for visualFrame: CGRect) -> CGRect {
        CGRect(x: visualFrame.minX, y: visualFrame.minY, width: visualFrame.width,
               height: max(0, bounds.maxY - visualFrame.minY))
    }

    private func click(_ id: String) {
        guard !suppressClick,
              let button = layoutResult.buttons.first(where: { $0.id == id }),
              let group = groups.first(where: { $0.id == button.groupID }) else { return }
        if button.isCombined { showWindowList(group: group, anchor: button.frame, focusForKeyboard: true) }
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
        contextMenu.dismiss()
    }

    func prepareForHiding() {
        dismissPopups()
        cancelFileHover()
        endGroupDrag(event: nil, cancelled: true)
    }

    private func screenAnchor(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func showWindowList(group: TaskbarGroupPresentation, anchor: CGRect, focusForKeyboard: Bool = false) {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        dismissTask?.cancel()
        if listGroupID == group.id && listSignature == group.windows.map(\.id) && popup.isPresented {
            if focusForKeyboard { popup.focusForKeyboard() }
            return
        }
        let view = TaskbarWindowListView(windows: group.windows,
                                      availableHeight: screen.visibleFrame.height - TaskbarMetrics.height - 24,
                                      delay: delay,
                                      icon: iconProvider,
                                      activate: { [weak self] item in self?.activateIfLive(item, dismiss: true) },
                                      close: { [weak self] item in self?.closeIfLive(item.item.actionWindowID) },
                                      fileHover: { [weak self] item in self?.activateIfLive(item, dismiss: false) })
        let frame = TaskbarPopupGeometry.frame(anchor: screenAnchor(anchor), contentSize: view.frame.size, screen: screen.frame)
        popup.present(content: view, frame: frame, anchorWindow: window)
        if focusForKeyboard { popup.focusForKeyboard() }
        windowList = view
        listGroupID = group.id
        listSignature = group.windows.map(\.id)
        view.onHover = { [weak self] entered in
            if entered { self?.dismissTask?.cancel() }
            else { self?.scheduleDismiss() }
        }
    }

    private func showOverflow(focusForKeyboard: Bool = false) {
        guard let anchor = layoutResult.overflowFrame else { return }
        let ids = Set(layoutResult.overflowGroups)
        let windows = groups.filter { ids.contains($0.id) }.flatMap(\.windows)
        showWindowList(group: TaskbarGroupPresentation(id: "overflow", name: String(localized: "More windows"), windows: windows),
                    anchor: anchor, focusForKeyboard: focusForKeyboard)
    }

    private func showContextMenu(buttonID: String, event: NSEvent) {
        guard let button = layoutResult.buttons.first(where: { $0.id == buttonID }),
              let group = groups.first(where: { $0.id == button.groupID }) else { return }
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
        contextMenu.present(entries: entries, event: event, view: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        dismissPopups()
        actions.backgroundMenu(event, self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { dismissPopups() }
    }

    private func dragFrames(in result: TaskbarLayoutResult) -> (slot: CGRect, displayed: CGRect)? {
        guard let id = draggedGroupID, let dragGeometry else { return nil }
        let slot = result.buttons.filter { $0.groupID == id }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !slot.isNull else { return nil }
        let occupied = result.buttons.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return (slot, dragGeometry.frame(pointer: dragPointer, groupWidth: slot.width, occupiedBounds: occupied))
    }

    private func beginGroupDrag(_ id: String, event: NSEvent, start: CGPoint) {
        guard let group = groups.first(where: { $0.id == id }), !group.windows.isEmpty else { return }
        dismissPopups()
        cancelFileHover()
        let rectangles = layoutResult.buttons.filter { $0.groupID == id }.map(\.frame)
        guard let first = rectangles.first else { return }
        let frame = rectangles.dropFirst().reduce(first) { $0.union($1) }
        draggedGroupID = id
        dragMembers = group.windows.map(\.id)
        dragButtonIDs = Set(layoutResult.buttons.filter { $0.groupID == id }.map(\.id))
        dragPointer = convert(event.locationInWindow, from: nil)
        dragGeometry = .make(pointer: convert(start, from: nil), groupFrame: frame)
        suppressClick = true
        if window != nil { installDragCancellation() }
        needsLayout = true
    }

    private func moveGroupDrag(event: NSEvent) {
        guard let id = draggedGroupID else { return }
        dragPointer = convert(event.locationInWindow, from: nil)
        if bounds.contains(dragPointer), let frames = dragFrames(in: layoutResult) {
            groupDrag.update(groupID: id, draggedFrame: frames.displayed,
                             buttons: layoutResult.buttons, liveGroups: groups.map(\.id))
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func endGroupDrag(event: NSEvent?, cancelled: Bool) {
        guard let id = draggedGroupID else { return }
        let inside = event.map { bounds.contains(convert($0.locationInWindow, from: nil)) } ?? false
        let target = !cancelled && inside ? groupDrag.target : nil
        if let target {
            let lookup = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups = groupDrag.order(groups.map(\.id)).compactMap { lookup[$0] }
            actions.reorder(id, target.groupID, target.after)
        }
        draggedGroupID = nil
        dragGeometry = nil
        dragMembers = []
        dragButtonIDs = []
        groupDrag.cancel()
        suppressClick = false
        if let localDragMonitor { NSEvent.removeMonitor(localDragMonitor) }
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor) }
        localDragMonitor = nil
        globalDragMonitor = nil
        animateNextLayout = true
        needsLayout = true
    }

    private func installDragCancellation() {
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.endGroupDrag(event: nil, cancelled: true) }
            return nil
        }
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.endGroupDrag(event: nil, cancelled: true) }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
           let frame = overflowButton?.frame, frame.contains(point) {
            fileHover.schedule(target: "overflow", after: .milliseconds(600)) { [weak self] in self?.showOverflow() }
            return .generic
        }
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
              let button = layoutResult.buttons.first(where: { buttonViews[$0.id]?.frame.contains(point) == true }),
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
        return false
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
