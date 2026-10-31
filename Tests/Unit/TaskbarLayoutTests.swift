import XCTest

final class TaskbarLayoutTests: XCTestCase {
    private func group(_ id: String, count: Int, width: CGFloat = 140) -> TaskbarLayoutGroup {
        TaskbarLayoutGroup(id: id, desiredWidth: 90,
                           windows: (0..<count).map { TaskbarLayoutWindow(id: "\(id)-\($0)", desiredWidth: width) })
    }

    func testWindowsRemainSeparateAndLabeledWhileTheirMinimumWidthsFit() {
        let result = TaskbarLayout.resolve(groups: [group("editor", count: 3), group("browser", count: 1)], width: 380)
        XCTAssertEqual(result.buttons.map(\.windowIDs), [["editor-0"], ["editor-1"], ["editor-2"], ["browser-0"]])
        XCTAssertTrue(result.buttons.allSatisfy { !$0.isCombined && $0.frame.width >= 80 })
        XCTAssertTrue(result.combinedGroups.isEmpty)
        XCTAssertTrue(result.overflowGroups.isEmpty)
        XCTAssertLessThan(result.buttons[0].frame.width, 140)
    }

    func testCrowdingCombinesOnlyTheNecessaryApplicationGroup() {
        let result = TaskbarLayout.resolve(groups: [group("editor", count: 3), group("browser", count: 1)], width: 340)
        XCTAssertEqual(result.buttons.count, 2)
        XCTAssertEqual(result.buttons[0].windowIDs, ["editor-0", "editor-1", "editor-2"])
        XCTAssertTrue(result.buttons[0].isCombined)
        XCTAssertFalse(result.buttons[1].isCombined)
        XCTAssertEqual(result.combinedGroups, ["editor"])
    }

    func testFreedSpaceRestoresIndividualButtonsAndTheirOrder() {
        let groups = [group("editor", count: 3), group("browser", count: 1)]
        let compact = TaskbarLayout.resolve(groups: groups, width: 340)
        let expanded = TaskbarLayout.resolve(groups: groups, width: 600)
        XCTAssertTrue(compact.buttons[0].isCombined)
        XCTAssertEqual(expanded.buttons.flatMap(\.windowIDs), ["editor-0", "editor-1", "editor-2", "browser-0"])
        XCTAssertTrue(expanded.combinedGroups.isEmpty)
    }

    func testExactMinimumFitDoesNotCombinePrematurely() {
        let groups = [group("editor", count: 2)]
        XCTAssertEqual(TaskbarLayout.resolve(groups: groups, width: 182).buttons.count, 2)
        XCTAssertEqual(TaskbarLayout.resolve(groups: groups, width: 181).buttons.count, 1)
    }

    func testWindowsReferenceCanCombineTheEarlierSmallerGroupWhileTheLargerGroupRemainsSeparate() {
        let result = TaskbarLayout.resolve(groups: [group("terminal", count: 4), group("notepad", count: 19)], width: 1720)
        XCTAssertEqual(result.combinedGroups, ["terminal"])
        XCTAssertEqual(result.buttons.filter { $0.groupID == "notepad" }.count, 19)
    }

    func testCombiningALargerGroupRestoresOtherGroupsWhenTheyFitAgain() {
        let result = TaskbarLayout.resolve(groups: [group("terminal", count: 4), group("notepad", count: 23)], width: 1720)
        XCTAssertEqual(result.combinedGroups, ["notepad"])
        XCTAssertEqual(result.buttons.filter { $0.groupID == "terminal" }.count, 4)
    }

    func testLayoutIsIndependentForDifferentDisplayWidths() {
        let groups = [group("editor", count: 4)]
        XCTAssertEqual(TaskbarLayout.resolve(groups: groups, width: 1000).buttons.count, 4)
        XCTAssertEqual(TaskbarLayout.resolve(groups: groups, width: 300).buttons.count, 1)
        XCTAssertEqual(TaskbarLayout.resolve(groups: [group("editor", count: 1)], width: 300).buttons.count, 1)
        XCTAssertFalse(TaskbarLayout.resolve(groups: [group("editor", count: 1)], width: 300).buttons[0].isCombined)
    }

    func testStartInsetIsReusedWithoutReservingSpaceForTheRemovedStartButton() {
        let result = TaskbarLayout.resolve(groups: [group("editor", count: 1)], width: 1920)
        XCTAssertEqual(result.buttons[0].frame.minX, 10)
        XCTAssertEqual(result.buttons[0].frame.minY, 2)
        XCTAssertEqual(result.buttons[0].frame.height, 28)
        XCTAssertEqual(TaskbarMetrics.height - result.buttons[0].frame.maxY, 2)
        XCTAssertEqual(TaskbarMetrics.iconSize, 16)
    }

    func testPanelTouchesEveryScreenBottomAndSpansItsFullWidth() {
        for screen in [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                       CGRect(x: -2560, y: -500, width: 2560, height: 1440),
                       CGRect(x: 100, y: 1080, width: 1512, height: 982)] {
            XCTAssertEqual(TaskbarMetrics.panelFrame(on: screen), CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 32))
        }
    }

    func testOverflowRetainsEveryWindowAndKeepsGroupsTogether() {
        let groups = (0..<20).map { group("app-\($0)", count: 2) }
        let result = TaskbarLayout.resolve(groups: groups, width: 400)
        XCTAssertNotNil(result.overflowFrame)
        let visible = Set(result.buttons.map(\.groupID))
        let overflow = Set(result.overflowGroups)
        XCTAssertTrue(visible.isDisjoint(with: overflow))
        XCTAssertEqual(visible.union(overflow), Set(groups.map(\.id)))
        XCTAssertLessThanOrEqual(result.overflowFrame!.maxX, 390)
    }

    func testShortTitlesKeepTheirWidthWhenLongTitlesShrink() {
        let groups = [group("short", count: 1, width: 80), group("long", count: 2, width: 164)]
        let result = TaskbarLayout.resolve(groups: groups, width: 350)
        XCTAssertEqual(result.buttons[0].frame.width, 80)
        XCTAssertEqual(result.buttons[1].frame.width, result.buttons[2].frame.width)
        XCTAssertLessThanOrEqual(result.buttons.last!.frame.maxX, 340)
    }

    func testEmptyAndInvalidGeometryRemainFinite() {
        XCTAssertTrue(TaskbarLayout.resolve(groups: [], width: 1920).buttons.isEmpty)
        for width in [CGFloat.zero, -100, .nan, .infinity] {
            let result = TaskbarLayout.resolve(groups: [group("a", count: 3)], width: width)
            XCTAssertTrue(result.buttons.allSatisfy { $0.frame.width.isFinite })
            XCTAssertEqual(result.overflowGroups, ["a"])
        }
        XCTAssertEqual(TaskbarMetrics.buttonWidth(textWidth: .nan), 80)
        XCTAssertEqual(TaskbarMetrics.buttonWidth(textWidth: 1000), 164)
    }

    func testDraggingMovesTheWholeGroupWithoutReorderingItsMembers() {
        let keys = ["a1": "a", "a2": "a", "b1": "b", "c1": "c"]
        let result = TaskbarGroupOrdering.moving("a", relativeTo: "c", after: true,
                                                order: ["a1", "a2", "b1", "c1"], appKeys: keys)
        XCTAssertEqual(result, ["b1", "c1", "a1", "a2"])
        XCTAssertEqual(TaskbarGroupOrdering.moving("a", relativeTo: "a", after: true,
                                                   order: result, appKeys: keys), result)
    }

    func testOlderIndividualOrderingIsNormalizedWithoutLosingWindows() {
        XCTAssertEqual(TaskbarGroupOrdering.contiguous(["a1", "b1", "a2", "a1"],
                                                       appKeys: ["a1": "a", "a2": "a", "b1": "b"]), ["a1", "a2", "b1"])
    }

    func testContextMenuStaysOnItsOwnScreenAndUsesTheMeasuredGap() {
        let screen = CGRect(x: -1920, y: -500, width: 1920, height: 1080)
        let frame = TaskbarPopupGeometry.frame(anchor: CGRect(x: -1910, y: -498, width: 140, height: 28),
                                                  contentSize: CGSize(width: 864, height: 154), screen: screen)
        XCTAssertEqual(frame.minX, -1912)
        XCTAssertEqual(frame.minY, -455)
        XCTAssertEqual(frame.width, 864)
        XCTAssertEqual(frame.height, 154)
    }
}
