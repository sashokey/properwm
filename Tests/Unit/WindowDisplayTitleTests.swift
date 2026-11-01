import XCTest

final class WindowDisplayTitleTests: XCTestCase {
    func testDisplayMetadataIsBoundedBeforeTextMeasurement() {
        let long = String(repeating: "x", count: 100_000)
        XCTAssertLessThanOrEqual(WindowDisplayTitle.resolve(rawTitle: long, fallbackName: "App").utf8.count, 4096)
        XCTAssertLessThanOrEqual(WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: long).utf8.count, 4096)
    }

    func testDisplayNameCacheReturnsTheSameBoundedValueOnAMissAndAHit() {
        let cache = AppDisplayNameCache()
        let long = "e" + String(repeating: "\u{0301}", count: 100_000)
        let first = cache.value(for: "long") { long }
        let second = cache.value(for: "long") { XCTFail("Expected cached name"); return "Other" }
        XCTAssertLessThanOrEqual(first.utf8.count, 4096)
        XCTAssertEqual(first, second)
    }

    func testDisplayNameCacheEvictsOldEntries() {
        let cache = AppDisplayNameCache()
        var loads = 0
        _ = cache.value(for: "first") { loads += 1; return "First" }
        for index in 0..<512 { _ = cache.value(for: "app-\(index)") { "App" } }
        _ = cache.value(for: "first") { loads += 1; return "First" }
        XCTAssertEqual(loads, 2)
    }

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
    }

    func testSeparateWindowsKeepTheirOrderAndTitles() {
        let items = StripItem.openWindows(from: snapshot([
            record("second"),
            record("first")
        ]))
        XCTAssertEqual(items.map(\.id), ["second", "first"])
    }

    func testMinimizedAndHiddenWindowsRemainWithoutACurrentCGIdentifier() {
        let items = StripItem.openWindows(from: snapshot([
            record("minimized", status: .minimized),
            record("hidden", status: .hidden)
        ]))
        XCTAssertEqual(items.map(\.id), ["minimized", "hidden"])
        XCTAssertEqual(items.map(\.status), ["minimized", "hidden"])
    }

    func testDisappearedWindowIsExcludedBeforeCountingCards() {
        let items = StripItem.openWindows(from: snapshot([
            record("gone", status: .disappeared),
            record("remaining")
        ]))
        XCTAssertEqual(items.map(\.id), ["remaining"])
    }

    func testNativeTabsKeepOneStableElementAndTheActiveActionTarget() {
        let background = record("tab-1", status: .minimized, cg: 1, group: "window-group")
        let foreground = record("tab-2", status: .active, cg: 2, group: "window-group")
        let items = StripItem.openWindows(from: snapshot([background, foreground]))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "window-group")
        XCTAssertEqual(items.first?.actionWindowID, "tab-2")
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
