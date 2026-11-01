import AppKit
import XCTest

@MainActor
final class TaskbarRendererTests: XCTestCase {
    private final class Popup: TaskbarPopupPresenting {
        var panel: NSPanel? { nil }
        var isPresented: Bool { content != nil }
        var onPresent: ((NSPanel) -> Void)?
        var onDismiss: (() -> Void)?
        var content: NSView?
        var presentations = 0
        var keyboardFocusRequests = 0

        func focusForKeyboard() { keyboardFocusRequests += 1 }

        func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
            dismiss()
            self.content = content
            presentations += 1
        }

        func dismiss() {
            (content as? TaskbarWindowListView)?.cancelPendingActions()
            content = nil
            onDismiss?()
        }
    }

    private final class ContextMenu: TaskbarContextMenuPresenting {
        var visibilityChanged: ((Bool) -> Void)?
        var menu: NSMenu?
        func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) {
            menu = TaskbarNativeMenuFactory.menu(entries: entries)
        }
        func dismiss() { menu = nil }
    }

    @MainActor
    private final class FileDrag: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation = CGPoint.zero
        var draggedImageLocation: NSPoint { draggingLocation }
        nonisolated var draggedImage: NSImage? { nil }
        let draggingPasteboard = NSPasteboard.withUniqueName()
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(location: NSPoint = .zero) {
            draggingLocation = location
            super.init()
            draggingPasteboard.declareTypes([.fileURL], owner: nil)
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    private final class RecordingPopupPanel: NSPanel {
        var frontRequests = 0
        var keyRequests = 0
        override var canBecomeKey: Bool { true }
        override func orderFrontRegardless() { frontRequests += 1 }
        override func makeKey() { keyRequests += 1 }
    }

    @MainActor
    private final class Clock {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var completed = 0
        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { waiters.append($0) }
            completed += 1
        }
        func advance() async {
            let deadline = ContinuousClock.now + .seconds(1)
            while waiters.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertFalse(waiters.isEmpty)
            let pending = waiters
            let completionCount = completed + pending.count
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
            while completed < completionCount, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertEqual(completed, completionCount)
            await Task.yield()
        }
    }

    private func groups(count: Int = 3) -> [TaskbarGroupPresentation] {
        let windows = (0..<count).map { index in
            let record = WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "editor"), pid: 100,
                                      bundleIdentifier: "test.editor", title: ["Project — Editor", "Notes — Editor", "A long document title — Editor"][index % 3],
                                      bounds: CGRect(x: 0, y: 0, width: 1430, height: 760), status: index == 0 ? .active : .inactive,
                                      cgWindowID: UInt32(index + 1), groupID: "window-\(index)", displayUUID: "left")
            return TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: index == 0)
        }
        return [TaskbarGroupPresentation(id: "test.editor", name: "Editor", windows: windows)]
    }

    private func makeView(width: CGFloat = 800) -> TaskbarView {
        _ = NSApplication.shared
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: width, height: 32))
        view.taskbarContent.iconProvider = { _ in NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) }
        return view
    }

    func testSurfaceUsesThePublicGlassContentHierarchy() {
        let view = makeView()
        XCTAssertEqual(view.style, .regular)
        XCTAssertEqual(view.cornerRadius, 0)
        XCTAssertNil(view.tintColor)
        XCTAssertTrue(view.contentView === view.taskbarContent)
    }

    func testRendererGivesEveryUncombinedWindowItsOwnButtonAndTitle() {
        let view = makeView()
        view.taskbarContent.update(groups: groups())
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 3)
        XCTAssertEqual(view.taskbarContent.buttonViews["window:window-0"]?.title, "Project — Editor")
        XCTAssertEqual(view.taskbarContent.buttonViews["window:window-0"]?.frame.minX, 10)
        XCTAssertTrue(view.taskbarContent.buttonViews["window:window-0"]?.isActiveWindow == true)
    }

    func testRepeatedUpdatesReuseViewsAndDoNotDuplicateButtons() {
        let view = makeView()
        view.taskbarContent.update(groups: groups())
        let original = view.taskbarContent.buttonViews["window:window-0"]
        for _ in 0..<20 { view.taskbarContent.update(groups: groups()) }
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 3)
        XCTAssertTrue(view.taskbarContent.buttonViews["window:window-0"] === original)
    }

    func testCrowdingAndFreedSpaceReplaceTheGroupWithTheCorrectLiveButtons() {
        let view = makeView(width: 200)
        view.taskbarContent.update(groups: groups())
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 1)
        XCTAssertEqual(view.taskbarContent.buttonViews["group:test.editor"]?.title, "Editor")
        view.frame.size.width = 800
        view.taskbarContent.frame.size.width = 800
        view.taskbarContent.update(groups: groups())
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 3)
        XCTAssertNil(view.taskbarContent.buttonViews["group:test.editor"])
    }

    func testAccessibilityPressRoutesToTheExactWindow() {
        let view = makeView()
        var toggled: [String] = []
        view.taskbarContent.actions.toggle = { toggled.append($0) }
        view.taskbarContent.update(groups: groups())
        XCTAssertTrue(view.taskbarContent.buttonViews["window:window-1"]!.accessibilityPerformPress())
        XCTAssertEqual(toggled, ["window-1"])
    }

    func testClosingLastWindowRemovesTheApplicationGroup() {
        let view = makeView()
        view.taskbarContent.update(groups: groups(count: 1))
        view.taskbarContent.update(groups: [])
        XCTAssertTrue(view.taskbarContent.buttonViews.isEmpty)
        XCTAssertTrue(view.taskbarContent.layoutResult.buttons.isEmpty)
    }

    func testHoveringSeparateButtonsNeverShowsATitleOrPreviewPopup() async {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        content.buttonViews["window:window-0"]?.onHover?(true)
        await clock.advance()
        XCTAssertEqual(popup.presentations, 0)
        XCTAssertNil(content.buttonViews["window:window-0"]?.toolTip)
    }

    func testCombinedButtonOpensAnOrderedIconAndTitleListWithoutActivatingAWindow() {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        let icon = NSImage(size: CGSize(width: 16, height: 16))
        content.iconProvider = { _ in icon }
        var activated: [String] = []
        content.actions.activate = { activated.append($0) }
        content.update(groups: groups())
        _ = content.buttonViews["group:test.editor"]?.accessibilityPerformPress()
        let list = popup.content as? TaskbarWindowListView
        XCTAssertEqual(list?.cells.map(\.item.title), groups()[0].windows.map(\.title))
        XCTAssertTrue(list?.cells.allSatisfy { $0.icon === icon } == true)
        XCTAssertEqual(list.map { value in value.cells.indices.map { value.tableView.rect(ofRow: $0).minY } }, [0, 40, 80])
        XCTAssertTrue(activated.isEmpty)
        XCTAssertTrue(list?.cells[1].accessibilityPerformPress() == true)
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertFalse(popup.isPresented)
    }

    func testFreedSpaceDismissesTheNowUnnecessaryGroupList() {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        content.update(groups: groups())
        _ = content.buttonViews["group:test.editor"]?.accessibilityPerformPress()
        XCTAssertTrue(popup.isPresented)
        content.frame.size.width = 800
        content.update(groups: groups())
        XCTAssertFalse(popup.isPresented)
    }

    func testClickPromotesAHoverListWithoutRecreatingIt() async {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        let button = content.buttonViews["group:test.editor"]!
        button.onHover?(true)
        await clock.advance()
        XCTAssertEqual(popup.presentations, 1)
        XCTAssertEqual(popup.keyboardFocusRequests, 0)
        let original = popup.content
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(popup.content === original)
        XCTAssertEqual(popup.presentations, 1)
        XCTAssertEqual(popup.keyboardFocusRequests, 1)
    }

    func testOverflowClickRequestsKeyboardFocus() {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 60, height: 32), popup: popup)
        content.update(groups: twoGroups())
        XCTAssertTrue(content.overflowButton?.accessibilityPerformPress() == true)
        XCTAssertTrue(popup.isPresented)
        XCTAssertEqual(popup.keyboardFocusRequests, 1)
    }

    func testPopupControllerRoutesPanelKeyboardEventsToItsList() throws {
        _ = NSApplication.shared
        let panel = RecordingPopupPanel(contentRect: CGRect(x: 0, y: 0, width: 216, height: 120),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let controller = TaskbarPopupController(makePanel: { _ in panel }, monitorsOutsideEvents: false)
        defer { controller.dismiss() }
        var activated: [String] = []
        let list = TaskbarWindowListView(windows: groups()[0].windows, availableHeight: 120, icon: { _ in nil },
                                        activate: { activated.append($0.id) }, close: { _ in }, fileHover: { _ in })
        controller.present(content: list, frame: list.bounds, anchorWindow: nil)
        XCTAssertEqual(panel.frontRequests, 1)
        XCTAssertEqual(panel.keyRequests, 0)
        controller.focusForKeyboard()
        XCTAssertEqual(panel.keyRequests, 1)
        XCTAssertTrue(panel.firstResponder === list)
        for code: UInt16 in [125, 125, 36, 53] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(panel.isVisible)
    }

    func testFileHoverRestoresOnlyTheExactSeparateWindow() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0) }
        content.update(groups: groups())
        content.scheduleFileHover(buttonID: "window:window-1")
        await clock.advance()
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertEqual(popup.presentations, 0)
    }

    func testClosingAFileHoverTargetPreventsDelayedActivation() async {
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup(),
                                         delay: { await clock.sleep($0) })
        var activated = false
        content.actions.activate = { _ in activated = true }
        content.update(groups: groups())
        content.scheduleFileHover(buttonID: "window:window-1")
        content.update(groups: groups(count: 1))
        await clock.advance()
        XCTAssertFalse(activated)
    }

    func testHidingThePanelCancelsPendingFileAndListHoverActions() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        content.buttonViews["group:test.editor"]?.onHover?(true)
        content.scheduleFileHover(buttonID: "group:test.editor")
        content.prepareForHiding()
        await clock.advance()
        XCTAssertEqual(popup.presentations, 0)
    }

    func testFileHoverOnCombinedButtonWaitsForTheUserToChooseAListRow() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0) }
        content.update(groups: groups())
        content.scheduleFileHover(buttonID: "group:test.editor")
        await clock.advance()
        XCTAssertTrue(activated.isEmpty)
        XCTAssertEqual(popup.keyboardFocusRequests, 0)
        let list = popup.content as? TaskbarWindowListView
        XCTAssertNotNil(list)
        list?.cells[2].scheduleFileHover()
        await clock.advance()
        XCTAssertEqual(activated, ["window-2"])
    }

    func testDismissedListCannotActivateAWindowFromItsDelayedFileHover() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated = false
        content.actions.activate = { _ in activated = true }
        content.update(groups: groups())
        _ = content.buttonViews["group:test.editor"]?.accessibilityPerformPress()
        let list = popup.content as? TaskbarWindowListView
        list?.cells[0].scheduleFileHover()
        content.prepareForHiding()
        await clock.advance()
        XCTAssertFalse(activated)
    }

    func testSeparateContextMenuClosesOneWindowAndThenOffersNormalQuit() {
        let popup = Popup()
        let context = ContextMenu()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup, contextMenu: context)
        var closed: [String] = []
        var quit = false
        content.actions.close = { closed.append($0) }
        content.actions.quit = { _ in quit = true }
        content.update(groups: groups())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        content.buttonViews["window:window-1"]?.onContextMenu?(event)
        let menu = context.menu
        XCTAssertEqual(menu?.items.map(\.title), ["Close window", "Quit"])
        menu?.performActionForItem(at: 0)
        XCTAssertEqual(closed, ["window-1"])
        XCTAssertFalse(quit)
    }

    func testKeyboardCanSelectAnExactWindowFromTheCombinedList() {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        var activated: [String] = []
        content.actions.activate = { activated.append($0) }
        content.update(groups: groups())
        _ = content.buttonViews["group:test.editor"]?.accessibilityPerformPress()
        let list = popup.content as? TaskbarWindowListView
        for code: UInt16 in [125, 125, 36] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: code)!
            list?.keyDown(with: event)
        }
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertFalse(popup.isPresented)
    }

    func testAStaleContextMenuCannotCloseAnAlreadyRemovedWindow() {
        let popup = Popup()
        let context = ContextMenu()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup, contextMenu: context)
        var closed: [String] = []
        content.actions.close = { closed.append($0) }
        content.update(groups: groups())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        content.buttonViews["window:window-1"]?.onContextMenu?(event)
        let menu = context.menu
        content.update(groups: groups(count: 1))
        menu?.performActionForItem(at: 0)
        XCTAssertTrue(closed.isEmpty)
    }

    func testStatusMenuKeepsHideIconBelowLoginAndQuitLast() {
        let login = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
        let hide = NSMenuItem(title: "Hide Status Bar Icon", action: nil, keyEquivalent: "")
        var quits = 0
        let menu = TaskbarNativeMenuFactory.statusMenu(launchAtLogin: login, hideStatusBarIcon: hide) { quits += 1 }
        XCTAssertTrue(menu.items.first === login)
        XCTAssertTrue(menu.items[1] === hide)
        XCTAssertEqual(menu.items.map(\.title), ["Open at Login", "Hide Status Bar Icon", "", "Quit"])
        XCTAssertEqual(menu.items.last?.title, "Quit")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertNil(menu.items.last?.view)
        menu.performActionForItem(at: menu.numberOfItems - 1)
        XCTAssertEqual(quits, 1)
    }

    func testContextMenuUsesSystemItemsInsteadOfCustomMenuViews() {
        var calls: [String] = []
        let menu = TaskbarNativeMenuFactory.menu(entries: [
            TaskbarMenuEntry(title: "Close window", symbol: "xmark") { calls.append("close") },
            TaskbarMenuEntry(title: "Quit", symbol: "power") { calls.append("quit") }
        ])
        XCTAssertEqual(menu.items.map(\.title), ["Close window", "Quit"])
        XCTAssertTrue(menu.items.allSatisfy { $0.view == nil })
        menu.performActionForItem(at: 1)
        XCTAssertEqual(calls, ["quit"])
    }

    private func mouseEvent(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testBottomScreenPixelRoutesHoverAndClickToTheExactWindowAtBothScales() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 64),
                            styleMask: .borderless, backing: .buffered, defer: true)
        defer { panel.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 64))
        panel.contentView = container
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        container.addSubview(content)
        var toggles: [String] = []
        content.actions.toggle = { toggles.append($0) }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["window:window-1"])
        button.reduceMotion = { true }
        for scale: CGFloat in [1, 2] {
            container.bounds.size = CGSize(width: 1600 * panel.backingScaleFactor / scale,
                                           height: 64 * panel.backingScaleFactor / scale)
            content.layoutSubtreeIfNeeded()
            button.updateTrackingAreas()
            let point = CGPoint(x: button.frame.midX, y: 32 - 0.5 / scale)
            let hit = try XCTUnwrap(content.hitTest(content.convert(point, to: container)))
            XCTAssertTrue(hit === button)
            let local = button.convert(point, from: content)
            let area = try XCTUnwrap(button.trackingAreas.first { $0.options.contains(.mouseEnteredAndExited) })
            let trackingRect = area.options.contains(.inVisibleRect) ? button.visibleRect : area.rect
            XCTAssertTrue(trackingRect.contains(local))
            XCTAssertFalse(trackingRect.contains(button.convert(CGPoint(x: button.frame.maxX + 1, y: point.y), from: content)))
            XCTAssertFalse(trackingRect.contains(button.convert(CGPoint(x: point.x, y: 32.25), from: content)))
            XCTAssertTrue(area.options.contains(.activeAlways))
            let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered,
                location: content.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            (area.owner as? NSResponder)?.mouseEntered(with: entered)
            XCTAssertGreaterThan(button.selectionView.alphaValue, 0)
            hit.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: content))
            hit.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: content))
            XCTAssertEqual(toggles.last, "window-1")
            XCTAssertEqual(button.selectionView.frame.height, 28)
            XCTAssertEqual(button.convert(button.selectionView.frame, to: content).minY, 2)
            XCTAssertEqual(button.iconView.frame, CGRect(x: 6, y: 6, width: 16, height: 16))
        }
        XCTAssertEqual(toggles, ["window-1", "window-1"])
        XCTAssertFalse(panel.isVisible)
    }

    func testBottomEdgeClickOpensCombinedAndOverflowLists() throws {
        for width: CGFloat in [200, 60] {
            let popup = Popup()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup)
            var toggles = 0
            content.actions.toggle = { _ in toggles += 1 }
            content.update(groups: groups())
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"])
            let point = CGPoint(x: button.frame.midX, y: 31.75)
            let hit = try XCTUnwrap(content.hitTest(content.convert(point, to: nil)))
            XCTAssertTrue(hit === button)
            hit.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: content))
            hit.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: content))
            XCTAssertEqual((popup.content as? TaskbarWindowListView)?.cells.map(\.item.id), groups()[0].windows.map(\.id))
            XCTAssertEqual(popup.keyboardFocusRequests, 1)
            XCTAssertEqual(toggles, 0)
        }
    }

    func testBottomTargetsPreserveGapsAndCancelMouseUpOutside() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        content.update(groups: groups())
        let first = try XCTUnwrap(content.buttonViews["window:window-0"])
        let second = try XCTUnwrap(content.buttonViews["window:window-1"])
        for point in [CGPoint(x: 5, y: 31.75),
                      CGPoint(x: (first.frame.maxX + second.frame.minX) / 2, y: 31.75),
                      CGPoint(x: 790, y: 31.75), CGPoint(x: first.frame.midX, y: 1)] {
            XCTAssertTrue(content.hitTest(content.convert(point, to: nil)) === content)
        }
        var toggles = 0
        content.actions.toggle = { _ in toggles += 1 }
        let inside = CGPoint(x: first.frame.midX, y: 31.75)
        let outside = CGPoint(x: first.frame.midX, y: 32.25)
        XCTAssertNil(content.hitTest(content.convert(outside, to: nil)))
        first.mouseDown(with: mouseEvent(.leftMouseDown, point: inside, in: content))
        first.mouseUp(with: mouseEvent(.leftMouseUp, point: outside, in: content))
        XCTAssertEqual(toggles, 0)
        first.isHidden = true
        XCTAssertTrue(content.hitTest(content.convert(inside, to: nil)) === content)
    }

    func testFileHoverAtTheBottomEdgeUsesTheSameWindowGroupAndOverflowTargets() async throws {
        let drag = FileDrag()
        defer { drag.draggingPasteboard.releaseGlobally() }
        for width: CGFloat in [800, 200, 60] {
            let popup = Popup()
            let clock = Clock()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            var activated: [String] = []
            content.actions.activate = { activated.append($0) }
            content.update(groups: groups())
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews[width == 200 ? "group:test.editor" : "window:window-1"])
            drag.draggingLocation = content.convert(CGPoint(x: button.frame.midX, y: 31.75), to: nil)
            XCTAssertEqual(content.draggingEntered(drag), .generic)
            await clock.advance()
            if width == 800 {
                XCTAssertEqual(activated, ["window-1"])
                XCTAssertFalse(popup.isPresented)
            } else {
                XCTAssertTrue(activated.isEmpty)
                XCTAssertEqual((popup.content as? TaskbarWindowListView)?.cells.map(\.item.id), groups()[0].windows.map(\.id))
                XCTAssertEqual(popup.keyboardFocusRequests, 0)
            }
            XCTAssertFalse(content.performDragOperation(drag))
            drag.draggingLocation = content.convert(CGPoint(x: button.frame.midX, y: 32.25), to: nil)
            XCTAssertEqual(content.draggingUpdated(drag), [])
            content.prepareForHiding()
        }
    }

    func testDraggingOutsideCannotLiftAnyGroupButtonOutOfTheBarOrActivateAWindow() {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var toggles = 0
        var moves = 0
        content.actions.toggle = { _ in toggles += 1 }
        content.actions.reorder = { _, _, _ in moves += 1 }
        content.update(groups: groups())
        let button = content.buttonViews["window:window-0"]!
        let start = CGPoint(x: button.frame.midX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        for point in [CGPoint(x: -500, y: -400), CGPoint(x: 3000, y: 700)] {
            button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: point, in: content))
            for view in content.buttonViews.values {
                XCTAssertEqual(view.frame.minY, 2)
                XCTAssertEqual(view.frame.maxY, content.bounds.maxY)
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.selectionView.frame.height, 28)
                XCTAssertGreaterThanOrEqual(view.frame.minX, 0)
                XCTAssertLessThanOrEqual(view.frame.maxX, content.bounds.width)
            }
        }
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: CGPoint(x: 3000, y: -400), in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(content.buttonViews["window:window-0"]?.frame.minX, 10)
    }

    private func twoGroups() -> [TaskbarGroupPresentation] {
        let editor = groups(count: 2)[0]
        let record = WindowRecord(id: WindowID(rawValue: "browser-window"), appID: AppID(rawValue: "browser"), pid: 200,
                                  bundleIdentifier: "test.browser", title: "Browser window", bounds: .zero, status: .inactive,
                                  cgWindowID: 20, groupID: "browser-window", displayUUID: "left")
        let browser = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: false)
        return [editor, TaskbarGroupPresentation(id: "test.browser", name: "Browser", windows: [browser])]
    }

    private func unequalGroups(shortFirst: Bool) -> [TaskbarGroupPresentation] {
        let specifications: [(String, [String])] = [
            ("narrow", ["Windows"]),
            ("wide", ["Release ProperWM 0.2.1", "New Tab — Google Chrome"])
        ]
        let result = specifications.enumerated().map { groupIndex, specification in
            let windows = specification.1.enumerated().map { index, title in
                let id = "\(specification.0)-\(index)"
                let record = WindowRecord(id: WindowID(rawValue: id), appID: AppID(rawValue: specification.0),
                                          pid: Int32(300 + groupIndex), bundleIdentifier: "test.\(specification.0)",
                                          title: title, bounds: .zero, status: .inactive,
                                          cgWindowID: UInt32(30 + groupIndex * 10 + index), groupID: id, displayUUID: "left")
                return TaskbarWindowPresentation(item: StripItem(record: record), title: title, isActive: false)
            }
            return TaskbarGroupPresentation(id: "test.\(specification.0)", name: specification.0, windows: windows)
        }
        return shortFirst ? result : result.reversed()
    }

    func testWideGroupSwapsWithANarrowNeighborFromEveryGrabPosition() throws {
        for shortFirst in [true, false] {
            for fraction in [CGFloat(0.02), 0.45, 0.98] {
                let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
                var moves: [String] = []
                var toggles = 0
                content.actions.reorder = { source, target, after in moves.append("\(source):\(target):\(after)") }
                content.actions.toggle = { _ in toggles += 1 }
                content.update(groups: unequalGroups(shortFirst: shortFirst))
                let original = content.layoutResult.buttons
                let wide = original.filter { $0.groupID == "test.wide" }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                let occupied = original.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                let offset = wide.width * fraction
                let start = CGPoint(x: wide.minX + offset, y: 16)
                let destinationX = shortFirst ? occupied.minX : occupied.maxX - wide.width
                let destination = CGPoint(x: destinationX + offset, y: 16)
                let button = try XCTUnwrap(content.buttonViews.values.first { $0.frame.contains(start) })
                button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
                let expected = shortFirst ? ["wide-0", "wide-1", "narrow-0"] : ["narrow-0", "wide-0", "wide-1"]
                for _ in 0..<5 {
                    button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
                    XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), expected,
                                   "shortFirst=\(shortFirst), grabFraction=\(fraction)")
                }
                button.mouseUp(with: mouseEvent(.leftMouseUp, point: destination, in: content))
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(moves, ["test.wide:test.narrow:\(!shortFirst)"])
                XCTAssertEqual(toggles, 0)
                XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), expected)
            }
        }
    }

    func testDraggingAWideGroupAwayAndBackDoesNotPersistOrToggleAnything() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var moves = 0
        var toggles = 0
        content.actions.reorder = { _, _, _ in moves += 1 }
        content.actions.toggle = { _ in toggles += 1 }
        content.update(groups: unequalGroups(shortFirst: true))
        let original = content.layoutResult
        let button = try XCTUnwrap(content.buttonViews["window:wide-1"])
        let wide = original.buttons.filter { $0.groupID == "test.wide" }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let start = CGPoint(x: button.frame.midX, y: 16)
        let moved = CGPoint(x: 10 + start.x - wide.minX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: moved, in: content))
        XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["wide-0", "wide-1", "narrow-0"])
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: start, in: content))
        XCTAssertEqual(content.layoutResult, original)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: start, in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(content.layoutResult, original)
    }

    func testDraggingAcrossAnotherApplicationCommitsTheWholeGroupInMemberOrder() {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var moves: [String] = []
        var toggles = 0
        content.actions.reorder = { source, target, after in moves.append("\(source):\(target):\(after)") }
        content.actions.toggle = { _ in toggles += 1 }
        content.update(groups: twoGroups())
        let button = content.buttonViews["window:window-0"]!
        let start = CGPoint(x: button.frame.midX, y: 16)
        let destination = CGPoint(x: content.buttonViews["window:browser-window"]!.frame.maxX - 4, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
        XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["browser-window", "window-0", "window-1"])
        XCTAssertEqual(content.buttonViews["window:window-1"]!.frame.minX - button.frame.maxX, 2)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: destination, in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(moves, ["test.editor:test.browser:true"])
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["browser-window", "window-0", "window-1"])
    }

    func testCancellingAReorderedGroupRestoresTheOriginalOrderWithoutPersisting() {
        for escape in [false, true] {
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
            var moves = 0
            var toggles = 0
            content.actions.reorder = { _, _, _ in moves += 1 }
            content.actions.toggle = { _ in toggles += 1 }
            content.update(groups: twoGroups())
            let button = content.buttonViews["window:window-0"]!
            let start = CGPoint(x: button.frame.midX, y: 16)
            let destination = CGPoint(x: content.buttonViews["window:browser-window"]!.frame.maxX - 4, y: 16)
            button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
            button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
            if escape { button.cancelOperation(nil) }
            button.mouseUp(with: mouseEvent(.leftMouseUp, point: CGPoint(x: destination.x, y: -400), in: content))
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(moves, 0)
            XCTAssertEqual(toggles, 0)
            XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["window-0", "window-1", "browser-window"])
        }
    }

    func testShrinkingTheBarDuringADragCancelsAHiddenSourceSafely() {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var moves = 0
        content.actions.reorder = { _, _, _ in moves += 1 }
        content.update(groups: twoGroups())
        let button = content.buttonViews["window:browser-window"]!
        let start = CGPoint(x: button.frame.midX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: CGPoint(x: start.x + 10, y: 16), in: content))
        content.frame.size.width = 100
        content.update(groups: twoGroups())
        XCTAssertNil(content.buttonViews["window:browser-window"])
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: CGPoint(x: 30, y: 16), in: content))
        content.frame.size.width = 800
        content.update(groups: twoGroups())
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(content.buttonViews["window:browser-window"]?.layer?.zPosition, 0)
        XCTAssertTrue(content.buttonViews.values.allSatisfy { $0.frame.minX.isFinite && $0.frame.width.isFinite })
    }

    func testNativeButtonsPreserveGeometryInEveryInteractionState() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 64),
                            styleMask: .borderless, backing: .buffered, defer: true)
        defer { panel.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 64))
        panel.contentView = container
        for title in [".", "Windows", "A very long window title that must truncate"] {
            let width = TaskbarMetrics.buttonWidth(textWidth: (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
            let button = TaskbarButtonView(frame: CGRect(x: 10, y: 2, width: width, height: 28))
            container.addSubview(button)
            defer { button.removeFromSuperview() }
            button.title = title
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            let native: NSButton = button
            XCTAssertFalse(native.isBordered)
            XCTAssertTrue(native.isTransparent)
            XCTAssertEqual(native.tintProminence, .none)
            XCTAssertEqual(button.selectionView.fillColor, .unemphasizedSelectedContentBackgroundColor)
            XCTAssertEqual(button.selectionView.cornerRadius, 4)
            button.reduceMotion = { true }
            XCTAssertEqual(native.title, title)
            for scale: CGFloat in [1, 2] {
                container.bounds.size = CGSize(width: 400 * panel.backingScaleFactor / scale,
                                               height: 64 * panel.backingScaleFactor / scale)
                for active in [false, true, false] {
                    button.isActiveWindow = active
                    button.needsLayout = true
                    button.layoutSubtreeIfNeeded()
                    XCTAssertEqual(native.state, active ? .on : .off)
                    XCTAssertEqual(native.frame, CGRect(x: 10, y: 2, width: width, height: 28))
                    XCTAssertEqual(button.iconView.frame, CGRect(x: 6, y: 6, width: 16, height: 16))
                    let textRect = button.titleLabel.alignmentRect(forFrame: button.titleLabel.frame)
                    XCTAssertEqual(textRect.minX, 28)
                    XCTAssertEqual(textRect.maxX, width - 8)
                    XCTAssertEqual(button.selectionView.frame, button.bounds)
                    XCTAssertEqual(button.indicator.frame, CGRect(x: active ? (scale == 1 ? 9 : 8.5) : 12,
                                                                 y: 25, width: active ? 11 : 4, height: 2))
                }
            }
        }
    }

    func testNativePressAndKeyboardActionsDoNotInventAnActiveWindow() {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        var calls = 0
        button.onClick = { calls += 1 }
        let point = CGPoint(x: 50, y: 14)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: button))
        XCTAssertTrue(button.isHighlighted)
        XCTAssertEqual(calls, 0)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: button))
        XCTAssertFalse(button.isHighlighted)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(button.state, .off)
        button.performClick(nil)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(button.state, .off)
        button.isActiveWindow = true
        button.performClick(nil)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(button.state, .on)
        button.isEnabled = false
        button.performClick(nil)
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(calls, 3)
    }

    func testHoverKeepsNeutralFeedbackAndPopupNotifications() async {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        var hovering: [Bool] = []
        button.onHover = { hovering.append($0) }
        for type: NSEvent.EventType in [.mouseEntered, .mouseExited] {
            let event = NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            if type == .mouseEntered { button.mouseEntered(with: event) }
            else { button.mouseExited(with: event) }
        }
        XCTAssertEqual(hovering, [true, false])
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        button.isActiveWindow = true
        let deadline = ContinuousClock.now + .seconds(1)
        while abs(button.selectionView.alphaValue - 0.65) > 0.001, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(button.selectionView.alphaValue, 0.65, accuracy: 0.001)
        XCTAssertEqual(button.selectionView.fillColor, .unemphasizedSelectedContentBackgroundColor)
    }

    func testWindowsReferenceDistinguishesHoverActiveAndHeldPress() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
            button.appearance = NSAppearance(named: appearance)
            button.reduceMotion = { true }
            var clicks = 0
            button.onClick = { clicks += 1 }
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            button.mouseEntered(with: enter)
            let hoverFill = button.selectionView.alphaValue
            let hoverBorder = button.selectionView.borderColor.alphaComponent
            XCTAssertGreaterThan(hoverFill, 0)
            XCTAssertEqual(button.selectionView.borderWidth, 1)
            XCTAssertEqual(button.indicator.frame.width, 4)
            button.mouseExited(with: exit)
            XCTAssertEqual(button.selectionView.alphaValue, 0)
            button.isActiveWindow = true
            let activeFill = button.selectionView.alphaValue
            let activeBorder = button.selectionView.borderColor.alphaComponent
            XCTAssertEqual(hoverFill, activeFill)
            XCTAssertGreaterThan(activeBorder, hoverBorder)
            XCTAssertEqual(button.indicator.frame.width, 11)
            button.mouseEntered(with: enter)
            let activeHoverFill = button.selectionView.alphaValue
            XCTAssertGreaterThan(activeHoverFill, activeFill)
            XCTAssertLessThan(button.selectionView.borderColor.alphaComponent, activeBorder)
            button.mouseDown(with: mouseEvent(.leftMouseDown, point: CGPoint(x: 50, y: 14), in: button))
            XCTAssertLessThan(button.selectionView.alphaValue, activeFill)
            XCTAssertEqual(button.selectionView.borderColor.alphaComponent, 0)
            XCTAssertEqual(clicks, 0)
            button.cancelOperation(nil)
            XCTAssertEqual(button.selectionView.alphaValue, activeHoverFill)
            XCTAssertEqual(clicks, 0)
            button.isActiveWindow = false
            XCTAssertEqual(button.selectionView.alphaValue, hoverFill)
            XCTAssertEqual(button.selectionView.borderColor.alphaComponent, hoverBorder)
            button.mouseExited(with: exit)
            XCTAssertEqual(button.selectionView.alphaValue, 0)
        }
    }

    func testActiveUnderlineMatchesTheSettledWindowsReferenceAtBothBackingScales() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 56),
                            styleMask: .borderless, backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        panel.contentView = content
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { true }
        content.addSubview(button)
        for scale: CGFloat in [1, 2, 1] {
            content.bounds.size = CGSize(width: 280 * panel.backingScaleFactor / scale,
                                         height: 56 * panel.backingScaleFactor / scale)
            for active in [false, true] {
                button.isActiveWindow = active
                button.needsLayout = true
                button.layoutSubtreeIfNeeded()
                let frame = button.indicator.frame
                XCTAssertEqual(frame.width, active ? 11 : 4)
                XCTAssertEqual(frame.height, 2)
                XCTAssertEqual(button.bounds.maxY - frame.maxY, 1)
                XCTAssertLessThanOrEqual(abs(frame.midX - button.iconView.frame.midX), 0.5 / scale)
                let backing = button.convertToBacking(frame)
                XCTAssertEqual(backing.width, (active ? 11 : 4) * scale)
                XCTAssertEqual(backing.height, 2 * scale)
                XCTAssertEqual(backing.minX, backing.minX.rounded())
                XCTAssertEqual(backing.minY, backing.minY.rounded())
            }
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testNeutralHighlightAndWindowsIndicatorsRespectReduceMotion() {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { true }
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        XCTAssertEqual(button.indicator.frame.size, CGSize(width: 4, height: 2))
        button.isActiveWindow = true
        XCTAssertGreaterThan(button.selectionView.alphaValue, 0)
        XCTAssertEqual(button.indicator.frame.size, CGSize(width: 11, height: 2))
        XCTAssertEqual(button.indicator.fillColor, .controlAccentColor)
        XCTAssertTrue(button.selectionView.layer?.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(button.indicator.layer?.animationKeys()?.isEmpty ?? true)
        button.isActiveWindow = false
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        XCTAssertEqual(button.indicator.fillColor, .secondaryLabelColor)
        XCTAssertEqual(button.indicator.frame.size, CGSize(width: 4, height: 2))
    }

    func testOverflowUsesANativeSymbolButtonAtTheExistingSize() throws {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 2, width: 32, height: 28))
        button.isOverflow = true
        button.title = "More windows"
        button.layoutSubtreeIfNeeded()
        XCTAssertNotNil(button.iconView.image)
        XCTAssertTrue(button.titleLabel.isHidden)
        XCTAssertTrue(button.indicator.isHidden)
        XCTAssertEqual(button.iconView.frame, CGRect(x: 8, y: 6, width: 16, height: 16))
        XCTAssertEqual(button.title, "More windows")
        XCTAssertNil(button.toolTip)
    }

    func testWindowListUsesGlassAndNativeRowsWithTheWindowsGeometry() throws {
        let windows = groups()[0].windows
        let list = TaskbarWindowListView(windows: windows, availableHeight: 80, icon: { _ in nil },
                                        activate: { _ in }, close: { _ in }, fileHover: { _ in })
        XCTAssertEqual(list.style, .regular)
        XCTAssertNil(list.tintColor)
        XCTAssertTrue(list.contentView === list.scrollView)
        XCTAssertFalse(list.scrollView.drawsBackground)
        XCTAssertFalse(list.scrollView.contentView.drawsBackground)
        XCTAssertEqual(list.tableView.backgroundColor, .clear)
        XCTAssertEqual(list.frame.size, CGSize(width: 216, height: 80))
        XCTAssertEqual(list.tableView.numberOfRows, 3)
        XCTAssertEqual(list.tableView.rowHeight, 40)
        XCTAssertEqual(list.tableView.intercellSpacing, .zero)
        for index in windows.indices {
            XCTAssertEqual(list.tableView.rect(ofRow: index), CGRect(x: 0, y: CGFloat(index) * 40, width: 216, height: 40))
            let cell: NSTableCellView = list.cells[index]
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.imageView?.frame, CGRect(x: 8, y: 12, width: 16, height: 16))
            let label = try XCTUnwrap(cell.textField)
            XCTAssertEqual(label.alignmentRect(forFrame: label.frame), CGRect(x: 32, y: 12, width: 148, height: 20))
            XCTAssertEqual(list.cells[index].closeButton.frame, CGRect(x: 180, y: 4, width: 32, height: 32))
            XCTAssertEqual(cell.textField?.stringValue, windows[index].title)
        }
        list.tableView.scrollRowToVisible(2)
        XCTAssertGreaterThan(list.scrollView.contentView.bounds.minY, 0)
    }

    func testNativeListCloseButtonClosesOnlyItsWindowWithoutActivatingIt() throws {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        var closed: [String] = []
        var activated: [String] = []
        content.actions.close = { closed.append($0) }
        content.actions.activate = { activated.append($0) }
        content.update(groups: groups())
        _ = content.buttonViews["group:test.editor"]?.accessibilityPerformPress()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let row = list.cells[1]
        row.keyboardSelected = true
        XCTAssertFalse(row.closeButton.isHidden)
        row.closeButton.performClick(nil)
        XCTAssertEqual(closed, ["window-1"])
        XCTAssertTrue(activated.isEmpty)
        XCTAssertTrue(popup.isPresented)
    }

    func testNativeTableKeyboardSelectionScrollsAndUpdatesTitlesWithoutRecreatingRows() {
        let windows = groups()[0].windows
        var activated: [String] = []
        let list = TaskbarWindowListView(windows: windows, availableHeight: 40, icon: { _ in nil },
                                        activate: { activated.append($0.id) }, close: { _ in }, fileHover: { _ in })
        let original = list.cells[2]
        for code: UInt16 in [126, 36] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: code)!
            list.tableView.keyDown(with: event)
        }
        XCTAssertEqual(activated, ["window-2"])
        XCTAssertEqual(list.tableView.selectedRow, 2)
        XCTAssertTrue(original.keyboardSelected)
        XCTAssertFalse(original.closeButton.isHidden)
        var updated = windows
        updated[2] = TaskbarWindowPresentation(item: windows[2].item, title: "Changed title", isActive: false)
        list.updateTitles(windows: updated)
        XCTAssertTrue(list.cells[2] === original)
        XCTAssertEqual(original.textField?.stringValue, "Changed title")
    }

    func testNativeTableMouseTrackingActivatesTheClickedRow() throws {
        _ = NSApplication.shared
        var activated: [String] = []
        let list = TaskbarWindowListView(windows: groups()[0].windows, availableHeight: 120, icon: { _ in nil },
                                        activate: { activated.append($0.id) }, close: { _ in }, fileHover: { _ in })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        XCTAssertFalse(panel.isVisible)
        let row = list.tableView.rect(ofRow: 1)
        let location = list.tableView.convert(CGPoint(x: 60, y: row.midY), to: nil)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 2,
                                                windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 1,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApplication.shared.postEvent(up, atStart: true)
        list.tableView.mouseDown(with: down)
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertFalse(panel.isVisible)
    }

    func testNativeListVisualFixturesRenderWithoutOpeningAWindow() throws {
        for dark in [false, true] {
            let list = TaskbarWindowListView(windows: groups()[0].windows, availableHeight: 120,
                                            icon: { _ in NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) },
                                            activate: { _ in }, close: { _ in }, fileHover: { _ in })
            list.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            list.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(list.bitmapImageRepForCachingDisplay(in: list.bounds))
            list.effectiveAppearance.performAsCurrentDrawingAppearance {
                list.cacheDisplay(in: list.bounds, to: bitmap)
            }
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 216)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 120)
            XCTAssertEqual(bitmap.pixelsWide * 120, bitmap.pixelsHigh * 216)
            if let path = ProcessInfo.processInfo.environment["PROPERWM_RENDER_PATH"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("list-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testRepresentativeVisualFixturesRenderWithoutScreenCapturePermission() async throws {
        let paths = ProcessInfo.processInfo.environment["PROPERWM_RENDER_PATH"]
        for dark in [false, true] {
            for (name, width, count) in [("separate", CGFloat(800), 3), ("combined", CGFloat(240), 8), ("single", CGFloat(800), 1)] {
                let view = makeView(width: width)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.taskbarContent.update(groups: groups(count: count))
                view.layoutSubtreeIfNeeded()
                let deadline = ContinuousClock.now + .seconds(1)
                for button in view.taskbarContent.buttonViews.values {
                    let expected: CGFloat = button.isActiveWindow ? 0.65 : 0
                    while abs(button.selectionView.alphaValue - expected) > 0.001, ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertEqual(button.selectionView.alphaValue, expected, accuracy: 0.001)
                }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    XCTFail("No render target for \(name)")
                    continue
                }
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                if let paths {
                    let directory = URL(fileURLWithPath: paths, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
                if let paths {
                    let directory = URL(fileURLWithPath: paths, isDirectory: true)
                    let content = view.taskbarContent
                    content.layer?.backgroundColor = NSColor(white: dark ? 0.11 : 0.94, alpha: 1).cgColor
                    content.layoutSubtreeIfNeeded()
                    content.effectiveAppearance.performAsCurrentDrawingAppearance {
                        content.displayIfNeeded()
                        for button in content.buttonViews.values {
                            button.layoutSubtreeIfNeeded()
                            button.displayIfNeeded()
                        }
                    }
                    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 64,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
                    context.translateBy(x: 0, y: 64)
                    context.scaleBy(x: 2, y: -2)
                    content.layer?.render(in: context)
                    try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("buttons-\(name)-\(dark ? "dark" : "light").png"))
                }
                view.taskbarContent.dismissPopups()
            }
        }
    }

}
