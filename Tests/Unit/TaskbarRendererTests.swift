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
        XCTAssertEqual(list?.cells.map(\.frame.minY), [0, 40, 80])
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
                XCTAssertEqual(view.frame.height, 28)
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

    func testHoverAndActiveStateUseAnimatedLayerTransitions() {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { false }
        button.layoutSubtreeIfNeeded()
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        button.mouseEntered(with: entered)
        XCTAssertNotNil(button.plateLayer.animation(forKey: "fillColor"))
        button.isActiveWindow = true
        XCTAssertEqual(button.indicatorLayer.bounds.width, 16)
        XCTAssertNotNil(button.indicatorLayer.animation(forKey: "bounds"))
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        XCTAssertNotNil(button.indicatorLayer.animation(forKey: "bounds"))
        button.isActiveWindow = false
        XCTAssertEqual(button.indicatorLayer.bounds.width, 4)
        XCTAssertNotNil(button.indicatorLayer.animation(forKey: "bounds"))
    }

    func testReduceMotionUpdatesTheButtonWithoutStartingAnimations() {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { true }
        button.isActiveWindow = true
        XCTAssertEqual(button.indicatorLayer.bounds.width, 16)
        XCTAssertTrue(button.indicatorLayer.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(button.plateLayer.animationKeys()?.isEmpty ?? true)
    }

    func testRepresentativeVisualFixturesRenderWithoutScreenCapturePermission() throws {
        let paths = ProcessInfo.processInfo.environment["PROPERWM_RENDER_PATH"]
        for dark in [false, true] {
            for (name, width, count) in [("separate", CGFloat(800), 3), ("combined", CGFloat(240), 8), ("single", CGFloat(800), 1)] {
                let view = makeView(width: width)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.taskbarContent.update(groups: groups(count: count))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    XCTFail("No render target for \(name)")
                    continue
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
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
                    content.displayIfNeeded()
                    for button in content.buttonViews.values {
                        button.layoutSubtreeIfNeeded()
                        button.displayIfNeeded()
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
