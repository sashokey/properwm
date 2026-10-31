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
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup)
        var closed: [String] = []
        var quit = false
        content.actions.close = { closed.append($0) }
        content.actions.quit = { _ in quit = true }
        content.update(groups: groups())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        content.buttonViews["window:window-1"]?.onContextMenu?(event)
        let menu = popup.content as? TaskbarMenuView
        XCTAssertEqual(menu?.subviews.map { $0.accessibilityLabel() }, ["Close window", "Quit"])
        XCTAssertTrue(menu?.subviews.first?.accessibilityPerformPress() == true)
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
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup)
        var closed: [String] = []
        content.actions.close = { closed.append($0) }
        content.update(groups: groups())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        content.buttonViews["window:window-1"]?.onContextMenu?(event)
        let menu = popup.content
        content.update(groups: groups(count: 1))
        _ = menu?.subviews.first?.accessibilityPerformPress()
        XCTAssertTrue(closed.isEmpty)
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
                view.taskbarContent.dismissPopups()
            }
        }
    }

}
