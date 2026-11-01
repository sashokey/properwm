import XCTest

final class TaskbarPresentationTests: XCTestCase {
    private func item(_ id: String, app: String = "editor", display: String? = "left",
                      status: WindowStatus = .inactive, title: String? = nil) -> StripItem {
        StripItem(record: WindowRecord(id: WindowID(rawValue: id), appID: AppID(rawValue: app), pid: 100,
                                       bundleIdentifier: "test." + app, title: title ?? id,
                                       bounds: CGRect(x: 0, y: 0, width: 1000, height: 600), status: status,
                                       cgWindowID: UInt32(abs(id.hashValue % 10000) + 1),
                                       groupID: id, displayUUID: display))
    }

    private func groups(_ items: [StripItem], order: [String], scope: String? = "left",
                        optimistic: [String: OptimisticWindowState] = [:]) -> [TaskbarGroupPresentation] {
        TaskbarPresentation.groups(items: items, order: order,
                                    filter: StripDisplayFilter(scope: scope, connectedUUIDs: ["left", "right"], primaryUUID: "left"),
                                    titles: [:], optimisticStates: optimistic, appName: { $0.appID })
    }

    func testOnlyTheDisplayContainingEachWindowContributesToItsGroup() {
        let items = [item("a", display: "left"), item("b", display: "right"), item("c", display: "left")]
        XCTAssertEqual(groups(items, order: ["a", "b", "c"]).flatMap(\.windows).map(\.id), ["a", "c"])
        XCTAssertEqual(groups(items, order: ["a", "b", "c"], scope: "right").flatMap(\.windows).map(\.id), ["b"])
    }

    func testUnknownOrDisconnectedDisplayFallsBackToPrimaryExactlyOnce() {
        let items = [item("unknown", display: nil), item("disconnected", display: "removed")]
        XCTAssertEqual(groups(items, order: items.map(\.id)).flatMap(\.windows).count, 2)
        XCTAssertTrue(groups(items, order: items.map(\.id), scope: "right").isEmpty)
    }

    func testActivationAndMinimizationDoNotReorderSiblings() {
        let base = [item("first"), item("second", status: .active), item("third", status: .minimized)]
        let order = ["first", "second", "third"]
        let before = groups(base, order: order)
        let after = groups(base, order: order, optimistic: ["third": OptimisticWindowState(status: .active, createdAt: Date())])
        XCTAssertEqual(before[0].windows.map(\.id), after[0].windows.map(\.id))
        XCTAssertTrue(after[0].windows[2].isActive)
    }

    func testWindowTitlesStayCompleteEvenForOneWindowPerApplication() {
        let result = groups([item("a", title: "Project — Editor")], order: ["a"])
        XCTAssertEqual(result[0].windows[0].title, "Project — Editor")
    }

    func testSeparateButtonClosesOnlyItsWindowThenOffersQuit() {
        let group = groups([item("a"), item("b")], order: ["a", "b"])[0]
        let layout = TaskbarButtonLayout(id: "window:b", groupID: group.id, windowIDs: ["b"], isCombined: false, frame: .zero)
        XCTAssertEqual(TaskbarContextMenuModel.actions(button: layout, group: group), [.closeWindow("b"), .quitApplication])
    }

    func testCombinedButtonClosesItsRepresentedWindowsThenOffersQuit() {
        let group = groups([item("a"), item("b")], order: ["a", "b"])[0]
        let layout = TaskbarButtonLayout(id: "group:editor", groupID: group.id, windowIDs: ["a", "b"], isCombined: true, frame: .zero)
        XCTAssertEqual(TaskbarContextMenuModel.actions(button: layout, group: group), [.closeWindows(["a", "b"]), .quitApplication])
    }

    func testCombinedMenuDoesNotCloseAWindowRepresentedOnAnotherDisplay() {
        let items = [item("a"), item("b"), item("remote", display: "right")]
        let group = groups(items, order: items.map(\.id))[0]
        let layout = TaskbarButtonLayout(id: "group:editor", groupID: group.id, windowIDs: ["a", "b"], isCombined: true, frame: .zero)
        XCTAssertEqual(TaskbarContextMenuModel.actions(button: layout, group: group), [.closeWindows(["a", "b"]), .quitApplication])
    }

    func testWindowsOnOtherSpacesAreExcludedFromCombinedGroupsAndCloseActions() {
        let items = [item("a"), item("b", status: .minimized), item("fullscreen")]
        let spaces = WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [2], currentSpaceID: 1)],
            memberships: Dictionary(uniqueKeysWithValues: items.map { ($0.spaceIdentity!, Set([$0.id == "fullscreen" ? 2 : 1])) }))
        let result = TaskbarPresentation.groups(items: items, order: items.map(\.id),
            filter: StripDisplayFilter(scope: "left", connectedUUIDs: ["left"], primaryUUID: "left"),
            titles: [:], optimisticStates: [:], spaces: spaces, appName: { $0.appID })
        XCTAssertEqual(result[0].windows.map(\.id), ["a", "b"])
        let button = TaskbarButtonLayout(id: "group:editor", groupID: result[0].id, windowIDs: result[0].windows.map(\.id), isCombined: true, frame: .zero)
        XCTAssertEqual(TaskbarContextMenuModel.actions(button: button, group: result[0]), [.closeWindows(["a", "b"]), .quitApplication])
    }
}
