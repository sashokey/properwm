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
