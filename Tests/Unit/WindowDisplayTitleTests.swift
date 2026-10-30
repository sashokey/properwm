import XCTest

final class WindowDisplayTitleTests: XCTestCase {
    func testNonemptyTitleIsReturnedUnchanged() {
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: "  System Settings  ", fallbackName: "Fallback"),
            "  System Settings  "
        )
    }

    func testMissingOrBlankTitleUsesFallbackName() {
        for title in [nil, "", " \n\t"] as [String?] {
            XCTAssertEqual(
                WindowDisplayTitle.resolve(rawTitle: title, fallbackName: "System Settings"),
                "System Settings"
            )
        }
    }

    func testMissingBundleIdentifierCanUseAppIDAsFallbackName() {
        let appID = "pid-456"

        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: appID),
            appID
        )
    }

    func testTaskbarNameUsesLocalizedDisplayName() {
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: "ProperWM", fallbackName: "Fallback"),
            String(localized: "Taskbar")
        )
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: "ProperWM"),
            String(localized: "Taskbar")
        )
    }

    // MARK: - trimmingAppNameSuffix（issue #41）

    func testTrailingAppNameSuffixIsRemoved() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02 - Google Chrome", appName: "Google Chrome"),
            "local-dc02"
        )
    }

    func testDashVariantsAreRecognized() {
        for separator in [" - ", " — ", " – ", " | ", " · ", "-"] {
            XCTAssertEqual(
                WindowDisplayTitle.trimmingAppNameSuffix("Cursor\(separator)Google Chrome", appName: "Google Chrome"),
                "Cursor",
                "分隔符「\(separator)」没被认出来"
            )
        }
    }

    func testOnlyTheLastSeparatorIsConsumed() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("README - macos-dock - Visual Studio Code",
                                                     appName: "Visual Studio Code"),
            "README - macos-dock"
        )
    }

    func testTitleWithoutTheAppNameIsUnchanged() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02", appName: "Google Chrome"),
            "local-dc02"
        )
    }

    func testTitleEqualToTheAppNameIsKept() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Google Chrome", appName: "Google Chrome"),
            "Google Chrome"
        )
    }

    /// 去掉后只剩分隔符 / 空白时必须原样留着——否则卡上会出现一张没有标签的窗口卡。
    func testTitleThatWouldBecomeEmptyIsKept() {
        for title in ["- Google Chrome", " - Google Chrome", "— Google Chrome"] {
            XCTAssertEqual(
                WindowDisplayTitle.trimmingAppNameSuffix(title, appName: "Google Chrome"),
                title
            )
        }
    }

    func testAppNameInTheMiddleIsNotTouched() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Google Chrome 更新说明", appName: "Google Chrome"),
            "Google Chrome 更新说明"
        )
    }

    /// v1 只处理后缀式重复；应用名在开头的应用原样返回（有需要再扩）。
    func testLeadingAppNameIsOutOfScopeForNow() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Safari — 起始页", appName: "Safari"),
            "Safari — 起始页"
        )
    }

    func testBlankAppNameIsIgnored() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02 - Google Chrome", appName: "   "),
            "local-dc02 - Google Chrome"
        )
    }
}

final class OpenWindowStripItemsTests: XCTestCase {
    func testEmptySnapshotAndAppsWithoutWindowsHaveNoElements() {
        XCTAssertTrue(StripItem.openWindows(from: .empty).isEmpty)
        let fallback = record("app-com.example")
        XCTAssertTrue(StripItem.openWindows(from: snapshot([fallback])).isEmpty)
    }

    func testFallbackDoesNotChangeTheRealWindowCountOrTitleStyle() {
        let items = StripItem.openWindows(from: snapshot([
            record("app-com.example"),
            record("window-1")
        ]))
        XCTAssertEqual(items.map(\.id), ["window-1"])
        XCTAssertEqual(items.first?.sameAppCardCount, 1)
        XCTAssertEqual(items.first?.showsTitle, false)
    }

    func testSeparateWindowsKeepTheirOrderAndTitles() {
        let items = StripItem.openWindows(from: snapshot([
            record("second"),
            record("first")
        ]))
        XCTAssertEqual(items.map(\.id), ["second", "first"])
        XCTAssertTrue(items.allSatisfy(\.showsTitle))
        XCTAssertTrue(items.allSatisfy { $0.sameAppCardCount == 2 })
    }

    func testMinimizedAndHiddenWindowsRemainWithoutACurrentCGIdentifier() {
        let items = StripItem.openWindows(from: snapshot([
            record("minimized", status: .minimized),
            record("hidden", status: .hidden)
        ]))
        XCTAssertEqual(items.map(\.id), ["minimized", "hidden"])
        XCTAssertEqual(items.map(\.status), ["minimized", "hidden"])
        XCTAssertTrue(items.allSatisfy { $0.canMinimize && $0.canClose })
    }

    func testDisappearedWindowIsExcludedBeforeCountingCards() {
        let items = StripItem.openWindows(from: snapshot([
            record("gone", status: .disappeared),
            record("remaining")
        ]))
        XCTAssertEqual(items.map(\.id), ["remaining"])
        XCTAssertEqual(items.first?.showsTitle, false)
    }

    func testNativeTabsKeepOneStableElementAndTheActiveActionTarget() {
        let background = record("tab-1", status: .minimized, cg: 1, group: "window-group")
        let foreground = record("tab-2", status: .active, cg: 2, group: "window-group")
        let items = StripItem.openWindows(from: snapshot([background, foreground]))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "window-group")
        XCTAssertEqual(items.first?.actionWindowID, "tab-2")
        XCTAssertEqual(items.first?.memberWindowIDs, ["tab-1", "tab-2"])
        XCTAssertEqual(items.first?.showsTitle, false)
    }

    func testMissingOrderedRecordDoesNotCreateAPlaceholder() {
        var state = snapshot([record("window")])
        state.orderedWindowIDs.insert(WindowID(rawValue: "missing"), at: 0)
        XCTAssertEqual(StripItem.openWindows(from: state).map(\.id), ["window"])
    }

    private func snapshot(_ records: [WindowRecord]) -> DockSnapshot {
        DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id)
        )
    }

    private func record(
        _ id: String,
        status: WindowStatus = .inactive,
        cg: UInt32? = nil,
        group: String = ""
    ) -> WindowRecord {
        WindowRecord(
            id: WindowID(rawValue: id),
            appID: AppID(rawValue: "app:com.example"),
            pid: 100,
            bundleIdentifier: "com.example",
            title: id,
            bounds: nil,
            status: status,
            cgWindowID: cg,
            groupID: group
        )
    }
}
