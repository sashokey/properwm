import XCTest
@testable import macos_dock_cc_v2

final class MessagingZoneAdmissionTests: XCTestCase {

    /// 把「应用名」表映射成 `titleMatchesAppName` 的全等语义。
    private func matcher(_ names: [String: String]) -> (String, String) -> Bool {
        { title, bundleID in
            guard let name = names[bundleID] else { return false }
            return title.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func win(_ bundleID: String, _ title: String, fallback: Bool = false) -> MessagingZoneAdmission.WindowFact {
        .init(bundleID: bundleID, title: title, isAppLevelFallback: fallback)
    }

    // MARK: - 能认出主窗口的进准入集

    func testTitleMatchingWindowQualifiesItsApp() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.xinWeChat"])
    }

    func testAppWithBothMainAndOtherWindowsStillQualifies() {
        // 微信主窗 + 「笔记」窗口并存:靠主窗命中。
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "笔记"),
                      win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.xinWeChat"])
    }

    // MARK: - 认不出的挡在门外(本次修复的核心)

    func testCatalystStyleNumericTitleNeverQualifies() {
        // Apple「信息」:标题是 UIScene 会话编号,与应用名永不相等。
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.apple.MobileSMS", "10691420171100425")],
            titleMatchesAppName: matcher(["com.apple.MobileSMS": "信息"])
        )
        XCTAssertTrue(ids.isEmpty, "认不出主窗口的应用不得进入消息区")
    }

    func testTerminalWithCommandTitleNeverQualifies() {
        // Ghostty:因社交类别被误判像消息应用,但窗口标题是命令名。
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.mitchellh.ghostty", "caye@mac: ~/Projects")],
            titleMatchesAppName: matcher(["com.mitchellh.ghostty": "Ghostty"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testWeChatWithOnlyNonMainWindowDoesNotQualifyThisRound() {
        // 主窗关闭只剩「笔记」:此刻认不出。调用方靠「一次通过即永久落名单」避免抖动,
        // 本判定只负责如实反映当前。
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "笔记")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - 边界

    func testAppLevelFallbackCannotProveIdentifiability() {
        // app-* 兜底项不是真实窗口,即使标题恰好等于应用名也不算数。
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "微信", fallback: true)],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testEmptyBundleIDIgnored() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("", "微信")],
            titleMatchesAppName: { _, _ in true }
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testMultipleAppsResolveIndependently() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.qq", "QQ"),
                      win("com.apple.MobileSMS", "10691420171100425"),
                      win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.qq": "QQ",
                                          "com.apple.MobileSMS": "信息",
                                          "com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.qq", "com.tencent.xinWeChat"])
    }

    func testNoWindowsYieldsEmpty() {
        XCTAssertTrue(MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [], titleMatchesAppName: { _, _ in true }
        ).isEmpty)
    }
}
